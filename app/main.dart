import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:archive/archive_io.dart' as ar;
import 'package:crypto/crypto.dart';
import 'package:file_picker/file_picker.dart';
import 'package:gal/gal.dart';
import 'package:open_file/open_file.dart';
import 'package:image_picker/image_picker.dart';
import 'package:nearby_connections/nearby_connections.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

const sid = 'com.femzap.app';
late SharedPreferences sp;
final nb = Nearby();
final st = S();
final walls = [
  [0xFF0B0B1A, 0xFF1B1F5E], [0xFF0F2027, 0xFF2C5364], [0xFF200122, 0xFF6f0000],
  [0xFF134E5E, 0xFF71B280], [0xFF232526, 0xFF414345], [0xFF1D2B64, 0xFFF8CDDA],
];

class S extends ChangeNotifier {
  String id = '', name = '', photo = '';
  Map con = {};
  List<Map> stk = [];
  Map packs = {};
  Map<String, List> msgs = {};
  final ep = <String, String>{}, eps = <String, String>{}, names = <String, String>{};
  final found = <String, String>{}, paths = <int, String>{}, done = <int>{};
  final pend = <String, ConnectionInfo>{};
  final metas = <int, Map>{};
  final q = <String, List<List>>{}, busy = <String, int>{}, pm = <int, String>{}, prog = <String, double>{};
  final fin = <int>{};

  void load() {
    final d = jsonDecode(sp.getString('d') ?? '{}');
    id = d['id'] ?? (Random().nextInt(1 << 31).toRadixString(36) + DateTime.now().millisecondsSinceEpoch.toRadixString(36));
    name = d['n'] ?? '';
    photo = d['p'] ?? '';
    con = d['c'] ?? {};
    (d['m'] ?? {}).forEach((k, v) => msgs[k] = List.from(v));
    stk = List<Map>.from(d['s'] ?? []);
    packs = d['k'] ?? {};
    save();
  }

  void save() {
    sp.setString('d', jsonEncode({'id': id, 'n': name, 'p': photo, 'c': con, 'm': msgs, 's': stk, 'k': packs}));
    notifyListeners();
  }

  String get un => '${name.replaceAll('|', '/')}|$id';

  Future<void> start() async {
    try {
      await [Permission.location, Permission.bluetoothScan, Permission.bluetoothAdvertise, Permission.bluetoothConnect, Permission.nearbyWifiDevices].request();
    } catch (_) {}
    _adv();
    _disco();
  }

  Future<void> _adv() async {
    try {
      await nb.startAdvertising(un, Strategy.P2P_CLUSTER,
          onConnectionInitiated: _init, onConnectionResult: _res, onDisconnected: _disc, serviceId: sid);
    } catch (_) {}
  }

  Future<void> _disco() async {
    try {
      await nb.startDiscovery(un, Strategy.P2P_CLUSTER, onEndpointFound: (e, n, s) {
        found[e] = n;
        final cid = n.split('|').last;
        if (con.containsKey(cid) && !ep.containsKey(cid) && id.compareTo(cid) > 0) req(e);
        notifyListeners();
      }, onEndpointLost: (e) {
        found.remove(e);
        notifyListeners();
      }, serviceId: sid);
    } catch (_) {}
  }

  void req(String e) => nb.requestConnection(un, e,
      onConnectionInitiated: _init, onConnectionResult: _res, onDisconnected: _disc).catchError((_) => false);

  void _init(String e, ConnectionInfo i) {
    names[e] = i.endpointName;
    if (con.containsKey(i.endpointName.split('|').last)) {
      acc(e);
    } else {
      pend[e] = i;
      notifyListeners();
    }
  }

  void acc(String e) {
    pend.remove(e);
    nb.acceptConnection(e, onPayLoadRecieved: _pay, onPayloadTransferUpdate: _upd);
    notifyListeners();
  }

  void rej(String e) {
    pend.remove(e);
    nb.rejectConnection(e);
    notifyListeners();
  }

  void _res(String e, Status s) {
    if (s != Status.CONNECTED) return;
    final p = (names[e] ?? '|').split('|');
    final cid = p.last;
    ep[cid] = e;
    eps[e] = cid;
    con.putIfAbsent(cid, () => {'name': p.first, 'photo': '', 'wall': 'g0', 'pin': false, 'mute': false});
    nb.stopDiscovery();
    nb.stopAdvertising();
    final dl = con[cid]['dels'];
    if (dl != null && dl.isNotEmpty) {
      _b(e, {'t': 'del', 'mids': List.from(dl)});
      con[cid]['dels'] = [];
    }
    if (photo.isNotEmpty) _sendFile(e, photo, {'k': 'photo'});
    for (final m in msgs[cid] ?? []) {
      if (m['me'] == true && m['st'] == 0) _push(cid, m);
    }
    save();
  }

  void _disc(String e) {
    final cid = eps.remove(e);
    if (cid != null) ep.remove(cid);
    busy.remove(e);
    q.remove(e);
    found.clear();
    _adv();
    _disco();
    notifyListeners();
  }

  void _b(String e, Map j) => nb.sendBytesPayload(e, Uint8List.fromList(utf8.encode(jsonEncode(j))));

  Future<void> _sendFile(String e, String path, Map meta) async {
    (q[e] ??= []).add([path, meta]);
    _next(e);
  }

  Future<void> _next(String e) async {
    if (busy.containsKey(e) || (q[e]?.isEmpty ?? true)) return;
    final it = q[e]!.removeAt(0);
    busy[e] = -1;
    try {
      final pid = await nb.sendFilePayload(e, it[0]);
      busy[e] = pid;
      pm[pid] = '${it[1]['mid'] ?? ''}';
      _b(e, {...it[1], 't': 'file', 'pid': pid, 'n': it[0].split('/').last});
      if (fin.contains(pid)) {
        busy.remove(e);
        _next(e);
      }
    } catch (_) {
      busy.remove(e);
    }
  }

  Future<void> addStk(String path, {bool sent = false}) async {
    final h = md5.convert(await File(path).readAsBytes()).toString();
    var x = stk.firstWhere((x) => x['h'] == h, orElse: () => {});
    if (x.isEmpty) {
      final d = await getApplicationDocumentsDirectory();
      final dir = Directory('${d.path}/stickers')..createSync(recursive: true);
      final i = path.lastIndexOf('.');
      final np = '${dir.path}/$h${i > path.lastIndexOf('/') ? path.substring(i) : ''}';
      await File(path).copy(np);
      x = {'h': h, 'p': np, 'fav': false, 'last': 0};
      stk.add(x);
    }
    if (sent) x['last'] = DateTime.now().millisecondsSinceEpoch;
    save();
  }

  bool _has(String cid, dynamic mid) => (msgs[cid] ?? []).any((m) => m['mid'] == mid);

  void del(String cid, Set<String> mids, bool all) {
    final l = msgs[cid] ?? [];
    for (final m in l.where((m) => mids.contains('${m['mid']}'))) {
      if (m['k'] != 'text') {
        try {
          File(m['t']).deleteSync();
        } catch (_) {}
      }
    }
    l.removeWhere((m) => mids.contains('${m['mid']}'));
    if (all) {
      final e = ep[cid];
      if (e != null) {
        _b(e, {'t': 'del', 'mids': mids.toList()});
      } else {
        (con[cid]['dels'] ??= []).addAll(mids);
      }
    }
    save();
  }

  Future<void> send(String cid, String k, String t) async {
    if (k != 'text') {
      final d = await getApplicationDocumentsDirectory();
      t = (await File(t).copy('${d.path}/${DateTime.now().microsecondsSinceEpoch}_${t.split('/').last}')).path;
    }
    if (k == 'sticker') await addStk(t, sent: true);
    final m = {'me': true, 'k': k, 't': t, 'ts': DateTime.now().millisecondsSinceEpoch,
      'mid': '${DateTime.now().microsecondsSinceEpoch}${Random().nextInt(99)}', 'st': 0};
    (msgs[cid] ??= []).add(m);
    save();
    _push(cid, m);
  }

  void _push(String cid, Map m) {
    final e = ep[cid];
    if (e == null) return;
    if (m['k'] == 'text') {
      _b(e, {'t': 'msg', 'mid': m['mid'], 'x': m['t']});
    } else {
      _sendFile(e, m['t'], {'k': m['k'], 'mid': m['mid']});
    }
  }

  void _pay(String e, Payload p) {
    final cid = eps[e];
    if (cid == null) return;
    if (p.type == PayloadType.BYTES) {
      final j = jsonDecode(utf8.decode(p.bytes!));
      if (j['t'] == 'msg') {
        if (!_has(cid, j['mid'])) (msgs[cid] ??= []).add({'me': false, 'k': 'text', 't': j['x'], 'ts': DateTime.now().millisecondsSinceEpoch, 'mid': j['mid'], 'st': 1});
        _b(e, {'t': 'ack', 'mid': j['mid']});
        save();
      } else if (j['t'] == 'ack') {
        for (final m in msgs[cid] ?? []) {
          if (m['mid'] == j['mid']) m['st'] = 1;
        }
        save();
      } else if (j['t'] == 'del') {
        final ids = List.from(j['mids']);
        for (final m in (msgs[cid] ?? []).where((m) => m['me'] == false && ids.contains('${m['mid']}'))) {
          if (m['k'] != 'text') {
            try {
              File(m['t']).deleteSync();
            } catch (_) {}
          }
        }
        msgs[cid]?.removeWhere((m) => m['me'] == false && ids.contains('${m['mid']}'));
        save();
      } else if (j['t'] == 'file') {
        metas[j['pid']] = j;
        _try(e, j['pid']);
      }
    } else if (p.type == PayloadType.FILE) {
      String? u;
      try {
        u = (p as dynamic).uri?.toString();
      } catch (_) {}
      try {
        u ??= (p as dynamic).filePath;
      } catch (_) {}
      if (u == null) return;
      paths[p.id] = u;
      _try(e, p.id);
    }
  }

  void _upd(String e, PayloadTransferUpdate u) {
    final mid = pm[u.id];
    if (mid != null && u.totalBytes > 0) {
      final v = u.bytesTransferred / u.totalBytes;
      if (v - (prog[mid] ?? 0) > 0.02 || v >= 1) {
        prog[mid] = v;
        notifyListeners();
      }
    }
    if (u.status != PayloadStatus.IN_PROGRESS) {
      fin.add(u.id);
      if (busy[e] == u.id) {
        busy.remove(e);
        _next(e);
      }
    }
    if (u.status == PayloadStatus.SUCCESS) {
      done.add(u.id);
      _try(e, u.id);
    }
  }

  Future<void> _try(String e, int pid) async {
    final j = metas[pid], src = paths[pid], cid = eps[e];
    if (j == null || src == null || cid == null || !done.contains(pid)) return;
    metas.remove(pid);
    final d = await getApplicationDocumentsDirectory();
    final dest = '${d.path}/${DateTime.now().microsecondsSinceEpoch}_${j['n']}';
    try {
      await (nb as dynamic).copyFileAndDeleteOriginal(src, dest);
    } catch (_) {}
    if (!File(dest).existsSync()) {
      try {
        await File(src).copy(dest);
      } catch (_) {
        return;
      }
    }
    if (j['k'] == 'photo') {
      con[cid]['photo'] = dest;
    } else {
      if (!_has(cid, j['mid'])) (msgs[cid] ??= []).add({'me': false, 'k': j['k'], 't': dest, 'ts': DateTime.now().millisecondsSinceEpoch, 'mid': j['mid'], 'st': 1});
      if (j['k'] == 'sticker') await addStk(dest);
      _b(e, {'t': 'ack', 'mid': j['mid']});
    }
    save();
  }
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  sp = await SharedPreferences.getInstance();
  st.load();
  if (st.name.isNotEmpty) st.start();
  runApp(const FemZap());
}

class FemZap extends StatelessWidget {
  const FemZap({super.key});
  @override
  Widget build(BuildContext c) => MaterialApp(
        title: 'Fem-Zap',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(colorSchemeSeed: const Color(0xFF3B4BFF), useMaterial3: true),
        darkTheme: ThemeData(colorSchemeSeed: const Color(0xFF3B4BFF), brightness: Brightness.dark, useMaterial3: true),
        home: ListenableBuilder(listenable: st, builder: (c, _) => st.name.isEmpty ? const Setup() : const Home()),
      );
}

Widget av(String photo, String name, [double r = 22]) => CircleAvatar(
      radius: r,
      backgroundImage: photo.isNotEmpty ? FileImage(File(photo)) : null,
      child: photo.isEmpty ? Text(name.isEmpty ? '?' : name[0].toUpperCase()) : null,
    );

class Setup extends StatefulWidget {
  const Setup({super.key});
  @override
  State<Setup> createState() => _Setup();
}

class _Setup extends State<Setup> {
  late final c = TextEditingController(text: st.name);
  String photo = st.photo;
  @override
  Widget build(BuildContext ctx) => Scaffold(
        appBar: AppBar(title: const Text('Seu perfil')),
        body: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(children: [
            GestureDetector(
              onTap: () async {
                final f = await ImagePicker().pickImage(source: ImageSource.gallery);
                if (f != null) {
                  final d = await getApplicationDocumentsDirectory();
                  photo = (await File(f.path).copy('${d.path}/perfil_${DateTime.now().millisecondsSinceEpoch}.jpg')).path;
                  setState(() {});
                }
              },
              child: av(photo, c.text, 60),
            ),
            const SizedBox(height: 8),
            const Text('Toque para escolher a foto'),
            const SizedBox(height: 24),
            TextField(controller: c, decoration: const InputDecoration(labelText: 'Seu nome', border: OutlineInputBorder())),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: () {
                if (c.text.trim().isEmpty) return;
                final first = st.name.isEmpty;
                st.name = c.text.trim();
                st.photo = photo;
                st.save();
                if (first) st.start();
                if (Navigator.canPop(ctx)) Navigator.pop(ctx);
              },
              child: const Text('Salvar'),
            ),
          ]),
        ),
      );
}

Widget pendTiles() => Column(children: [
      for (final e in st.pend.entries)
        Card(
          child: ListTile(
            title: Text('${e.value.endpointName.split('|').first} quer conversar'),
            subtitle: Text('Código: ${e.value.authenticationToken}'),
            trailing: Row(mainAxisSize: MainAxisSize.min, children: [
              IconButton(icon: const Icon(Icons.close), onPressed: () => st.rej(e.key)),
              IconButton(icon: const Icon(Icons.check), onPressed: () => st.acc(e.key)),
            ]),
          ),
        ),
    ]);

class Home extends StatelessWidget {
  const Home({super.key});
  @override
  Widget build(BuildContext c) {
    final ids = st.con.keys.cast<String>().toList()
      ..sort((a, b) => (st.con[b]['pin'] == true ? 1 : 0) - (st.con[a]['pin'] == true ? 1 : 0));
    return Scaffold(
      appBar: AppBar(
        title: Row(children: [Image.asset('assets/logo.png', width: 32), const SizedBox(width: 8), const Text('Fem-Zap')]),
        actions: [
          IconButton(icon: const Icon(Icons.person), onPressed: () => Navigator.push(c, MaterialPageRoute(builder: (_) => const Setup()))),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        icon: const Icon(Icons.bluetooth_searching),
        label: const Text('Buscar contatos'),
        onPressed: () => Navigator.push(c, MaterialPageRoute(builder: (_) => const Nearby0())),
      ),
      body: ListView(children: [
        pendTiles(),
        if (ids.isEmpty)
          const Padding(padding: EdgeInsets.all(32), child: Text('Nenhum contato ainda. Toque em "Buscar contatos" com o outro aparelho por perto.', textAlign: TextAlign.center)),
        for (final id in ids)
          ListTile(
            leading: av(st.con[id]['photo'], st.con[id]['name']),
            title: Text(st.con[id]['name']),
            subtitle: Text(_last(id), maxLines: 1, overflow: TextOverflow.ellipsis),
            trailing: Row(mainAxisSize: MainAxisSize.min, children: [
              if (st.con[id]['pin'] == true) const Icon(Icons.push_pin, size: 16),
              if (st.con[id]['mute'] == true) const Icon(Icons.volume_off, size: 16),
              if (st.ep.containsKey(id)) const Icon(Icons.circle, size: 12, color: Colors.green),
            ]),
            onTap: () => Navigator.push(c, MaterialPageRoute(builder: (_) => Chat(id))),
          ),
      ]),
    );
  }

  String _last(String id) {
    final l = st.msgs[id];
    if (l == null || l.isEmpty) return 'Toque para conversar';
    final m = l.last;
    return m['k'] == 'text' ? m['t'] : '📎 ${m['k']}';
  }
}

class Nearby0 extends StatelessWidget {
  const Nearby0({super.key});
  @override
  Widget build(BuildContext c) => Scaffold(
        appBar: AppBar(title: const Text('Aparelhos por perto')),
        body: ListenableBuilder(
          listenable: st,
          builder: (c, _) => ListView(children: [
            pendTiles(),
            for (final e in st.found.entries)
              if (!st.eps.containsKey(e.key))
                ListTile(
                  leading: av('', e.value.split('|').first),
                  title: Text(e.value.split('|').first),
                  subtitle: const Text('Toque para conectar e salvar contato'),
                  onTap: () => st.req(e.key),
                ),
            if (st.found.isEmpty)
              const Padding(padding: EdgeInsets.all(32), child: Text('Procurando... peça para o outro abrir o Fem-Zap.', textAlign: TextAlign.center)),
          ]),
        ),
      );
}

class Chat extends StatefulWidget {
  final String cid;
  const Chat(this.cid, {super.key});
  @override
  State<Chat> createState() => _Chat();
}

class _Chat extends State<Chat> {
  final c = TextEditingController();
  final sel = <String>{};
  String get cid => widget.cid;
  Map get ct => st.con[cid];

  Future<void> askDel() async {
    final l = st.msgs[cid] ?? [];
    final mine = l.where((m) => sel.contains('${m['mid']}')).every((m) => m['me'] == true);
    final r = await showDialog<String>(
        context: context,
        builder: (_) => SimpleDialog(title: Text('Apagar ${sel.length} mensagem(ns)?'), children: [
              if (mine) SimpleDialogOption(onPressed: () => Navigator.pop(context, 'all'), child: const Text('Apagar para todos')),
              SimpleDialogOption(onPressed: () => Navigator.pop(context, 'me'), child: const Text('Apagar para mim')),
              SimpleDialogOption(onPressed: () => Navigator.pop(context), child: const Text('Cancelar')),
            ]));
    if (r == null) return;
    st.del(cid, Set.from(sel), r == 'all');
    setState(sel.clear);
  }

  Future<void> pick(String k) async {
    if (k == 'sticker') {
      showModalBottomSheet(context: context, isScrollControlled: true, builder: (_) => StkSheet(cid));
      return;
    }
    if (k == 'file' || k == 'zip') {
      final r = await FilePicker.platform.pickFiles();
      final path = r?.files.single.path;
      if (path == null) return;
      if (k == 'zip') {
        final t = await getTemporaryDirectory();
        final z = '${t.path}/${path.split('/').last}.zip';
        final enc = ar.ZipFileEncoder();
        enc.create(z);
        await enc.addFile(File(path));
        enc.close();
        st.send(cid, 'file', z);
      } else {
        st.send(cid, 'file', path);
      }
      return;
    }
    final p = ImagePicker();
    final f = k == 'video' ? await p.pickVideo(source: ImageSource.gallery) : await p.pickImage(source: ImageSource.gallery);
    if (f != null) st.send(cid, k, f.path);
  }

  Future<void> dl(Map m) async {
    try {
      await Gal.requestAccess();
      m['k'] == 'video' ? await Gal.putVideo(m['t']) : await Gal.putImage(m['t']);
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Salvo na galeria')));
    } catch (_) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Não foi possível salvar')));
    }
  }

  BoxDecoration wall() {
    final w = '${ct['wall']}';
    if (w.startsWith('/')) return BoxDecoration(image: DecorationImage(image: FileImage(File(w)), fit: BoxFit.cover));
    final g = walls[int.tryParse(w.replaceAll('g', '')) ?? 0];
    return BoxDecoration(gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [Color(g[0]), Color(g[1])]));
  }

  void pickWall() => showModalBottomSheet(
        context: context,
        builder: (_) => Padding(
          padding: const EdgeInsets.all(16),
          child: Wrap(spacing: 12, runSpacing: 12, children: [
            for (var i = 0; i < walls.length; i++)
              GestureDetector(
                onTap: () {
                  ct['wall'] = 'g$i';
                  st.save();
                  Navigator.pop(context);
                },
                child: CircleAvatar(radius: 24, backgroundColor: Color(walls[i][1])),
              ),
            ActionChip(
              avatar: const Icon(Icons.image),
              label: const Text('Foto da galeria'),
              onPressed: () async {
                final f = await ImagePicker().pickImage(source: ImageSource.gallery);
                if (f != null) {
                  final d = await getApplicationDocumentsDirectory();
                  ct['wall'] = (await File(f.path).copy('${d.path}/wall_${DateTime.now().millisecondsSinceEpoch}.jpg')).path;
                  st.save();
                }
                if (mounted) Navigator.pop(context);
              },
            ),
          ]),
        ),
      );

  Widget bubble(Map m) {
    final me = m['me'] == true;
    final k = m['k'];
    final mid = '${m['mid']}';
    final s = sel.contains(mid);
    final pr = st.prog[mid];
    Widget body;
    if (k == 'text') {
      body = Text(m['t'], style: const TextStyle(color: Colors.white, fontSize: 16));
    } else if (k == 'image' || k == 'gif' || k == 'sticker') {
      body = GestureDetector(
        onTap: () => showDialog(context: context, builder: (_) => Dialog(child: InteractiveViewer(child: Image.file(File(m['t']))))),
        child: Image.file(File(m['t']), width: k == 'sticker' ? 130 : 220),
      );
    } else if (k == 'file') {
      body = GestureDetector(
        onTap: () => OpenFile.open(m['t']),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.insert_drive_file, color: Colors.white),
          const SizedBox(width: 6),
          Flexible(child: Text('${m['t']}'.split('/').last.replaceFirst(RegExp(r'^(\d+_)+'), ''), style: const TextStyle(color: Colors.white))),
        ]),
      );
    } else {
      body = Row(mainAxisSize: MainAxisSize.min, children: const [
        Icon(Icons.videocam, color: Colors.white), SizedBox(width: 6), Text('Vídeo', style: TextStyle(color: Colors.white)),
      ]);
    }
    final canDl = k == 'image' || k == 'gif' || k == 'sticker' || k == 'video';
    final inner = Column(crossAxisAlignment: CrossAxisAlignment.end, mainAxisSize: MainAxisSize.min, children: [
      AbsorbPointer(absorbing: sel.isNotEmpty, child: body),
      if (pr != null && pr < 1) SizedBox(width: 160, child: LinearProgressIndicator(value: pr)),
      Row(mainAxisSize: MainAxisSize.min, children: [
        if (canDl)
          InkWell(onTap: () => dl(m), child: const Padding(padding: EdgeInsets.all(2), child: Icon(Icons.download, size: 16, color: Colors.white70))),
        if (me) Icon(m['st'] == 1 ? Icons.done_all : Icons.done, size: 14, color: m['st'] == 1 ? Colors.lightBlueAccent : Colors.white70),
      ]),
    ]);
    final bub = Align(
      alignment: me ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 3, horizontal: 10),
        padding: const EdgeInsets.all(8),
        constraints: const BoxConstraints(maxWidth: 280),
        decoration: k == 'sticker' ? null : BoxDecoration(color: me ? const Color(0xFF2B3BE0) : const Color(0xFF2A3050), borderRadius: BorderRadius.circular(14)),
        child: inner,
      ),
    );
    void tg() => setState(() => s ? sel.remove(mid) : sel.add(mid));
    return GestureDetector(
      onLongPress: tg,
      onTap: sel.isEmpty ? null : tg,
      child: Container(color: s ? const Color(0x593B4BFF) : null, child: bub),
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: st,
        builder: (context, _) {
          final l = st.msgs[cid] ?? [];
          return Scaffold(
            appBar: sel.isNotEmpty
                ? AppBar(leading: IconButton(icon: const Icon(Icons.close), onPressed: () => setState(sel.clear)), title: Text('${sel.length} selecionada(s)'))
                : AppBar(
              leading: IconButton(icon: const Icon(Icons.arrow_back), onPressed: () => Navigator.pop(context)),
              title: Row(children: [
                av(ct['photo'], ct['name'], 18), const SizedBox(width: 10),
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(ct['name'], style: const TextStyle(fontSize: 16)),
                  Text(st.ep.containsKey(cid) ? 'conectado' : 'fora de alcance', style: const TextStyle(fontSize: 12)),
                ]),
              ]),
              actions: [
                PopupMenuButton<String>(
                  onSelected: (v) {
                    if (v == 'w') pickWall();
                    if (v == 'p') ct['pin'] = ct['pin'] != true;
                    if (v == 'm') ct['mute'] = ct['mute'] != true;
                    st.save();
                  },
                  itemBuilder: (_) => [
                    const PopupMenuItem(value: 'w', child: Text('Papel de parede')),
                    PopupMenuItem(value: 'p', child: Text(ct['pin'] == true ? 'Desafixar' : 'Fixar')),
                    PopupMenuItem(value: 'm', child: Text(ct['mute'] == true ? 'Reativar som' : 'Silenciar')),
                  ],
                ),
              ],
            ),
            body: Container(
              decoration: wall(),
              child: Column(children: [
                Expanded(child: ListView.builder(reverse: true, itemCount: l.length, itemBuilder: (_, i) => bubble(l[l.length - 1 - i]))),
                sel.isNotEmpty
                    ? Container(
                        color: Theme.of(context).colorScheme.surface,
                        child: SafeArea(
                          child: Column(children: [
                            ListTile(leading: const Icon(Icons.delete), title: const Text('Apagar mensagem'), onTap: askDel),
                            ListTile(leading: const Icon(Icons.close), title: const Text('Cancelar'), onTap: () => setState(sel.clear)),
                          ]),
                        ),
                      )
                    : SafeArea(
                  child: Row(children: [
                    PopupMenuButton<String>(
                      icon: const Icon(Icons.attach_file),
                      onSelected: pick,
                      itemBuilder: (_) => const [
                        PopupMenuItem(value: 'image', child: Text('Foto')),
                        PopupMenuItem(value: 'video', child: Text('Vídeo')),
                        PopupMenuItem(value: 'sticker', child: Text('Figurinha')),
                        PopupMenuItem(value: 'gif', child: Text('GIF')),
                        PopupMenuItem(value: 'file', child: Text('Arquivo (Word, PDF...)')),
                        PopupMenuItem(value: 'zip', child: Text('Arquivo compactado (ZIP)')),
                      ],
                    ),
                    Expanded(child: TextField(controller: c, decoration: const InputDecoration(hintText: 'Mensagem', filled: true, border: OutlineInputBorder(borderRadius: BorderRadius.all(Radius.circular(24)), borderSide: BorderSide.none)))),
                    IconButton(
                      icon: const Icon(Icons.send),
                      onPressed: () {
                        if (c.text.trim().isEmpty) return;
                        st.send(cid, 'text', c.text.trim());
                        c.clear();
                      },
                    ),
                  ]),
                ),
              ]),
            ),
          );
        },
      );
}

class StkSheet extends StatefulWidget {
  final String cid;
  const StkSheet(this.cid, {super.key});
  @override
  State<StkSheet> createState() => _Stk();
}

class _Stk extends State<StkSheet> {
  String blk = 'Recentes';

  List<Map> get items {
    if (blk == 'Todas') return st.stk;
    if (blk == 'Favoritas') return st.stk.where((x) => x['fav'] == true).toList();
    if (blk == 'Recentes') {
      final l = st.stk.where((x) => (x['last'] ?? 0) > 0).toList()..sort((a, b) => (b['last'] as int).compareTo(a['last'] as int));
      return l.take(30).toList();
    }
    final hs = st.packs[blk] ?? [];
    return st.stk.where((x) => hs.contains(x['h'])).toList();
  }

  Future<void> newPack() async {
    final c = TextEditingController();
    final n = await showDialog<String>(
        context: context,
        builder: (_) => AlertDialog(
              title: const Text('Novo bloco'),
              content: TextField(controller: c, decoration: const InputDecoration(hintText: 'Nome do bloco')),
              actions: [
                TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancelar')),
                TextButton(onPressed: () => Navigator.pop(context, c.text.trim()), child: const Text('Criar')),
              ],
            ));
    if (n != null && n.isNotEmpty && !['Recentes', 'Todas', 'Favoritas'].contains(n)) {
      st.packs.putIfAbsent(n, () => []);
      st.save();
      setState(() => blk = n);
    }
  }

  void opts(Map x) => showModalBottomSheet(
        context: context,
        builder: (_) => ListView(shrinkWrap: true, children: [
          ListTile(
            leading: Icon(x['fav'] == true ? Icons.star : Icons.star_border),
            title: Text(x['fav'] == true ? 'Tirar das favoritas' : 'Favoritar'),
            onTap: () {
              x['fav'] = x['fav'] != true;
              st.save();
              Navigator.pop(context);
              setState(() {});
            },
          ),
          for (final n in st.packs.keys)
            ListTile(
              leading: const Icon(Icons.folder),
              title: Text(st.packs[n].contains(x['h']) ? 'Tirar de "$n"' : 'Adicionar a "$n"'),
              onTap: () {
                st.packs[n].contains(x['h']) ? st.packs[n].remove(x['h']) : st.packs[n].add(x['h']);
                st.save();
                Navigator.pop(context);
                setState(() {});
              },
            ),
        ]),
      );

  @override
  Widget build(BuildContext context) => SafeArea(
        child: SizedBox(
          height: MediaQuery.of(context).size.height * 0.55,
          child: Column(children: [
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.all(8),
              child: Row(children: [
                for (final b in ['Recentes', 'Todas', 'Favoritas', ...st.packs.keys])
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: ChoiceChip(label: Text('$b'), selected: blk == b, onSelected: (_) => setState(() => blk = '$b')),
                  ),
                ActionChip(avatar: const Icon(Icons.create_new_folder), label: const Text('Novo bloco'), onPressed: newPack),
                const SizedBox(width: 6),
                ActionChip(
                  avatar: const Icon(Icons.add_photo_alternate),
                  label: const Text('Importar'),
                  onPressed: () async {
                    final f = await ImagePicker().pickImage(source: ImageSource.gallery);
                    if (f != null) {
                      await st.addStk(f.path);
                      setState(() {});
                    }
                  },
                ),
              ]),
            ),
            Expanded(
              child: items.isEmpty
                  ? const Center(child: Text('Nenhuma figurinha aqui ainda'))
                  : GridView.count(crossAxisCount: 4, children: [
                      for (final x in items)
                        GestureDetector(
                          onTap: () {
                            st.send(widget.cid, 'sticker', x['p']);
                            Navigator.pop(context);
                          },
                          onLongPress: () => opts(x),
                          child: Padding(padding: const EdgeInsets.all(4), child: Image.file(File(x['p']))),
                        ),
                    ]),
            ),
          ]),
        ),
      );
}
