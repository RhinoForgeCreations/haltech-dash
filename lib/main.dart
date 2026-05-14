import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  runApp(const HaltechApp());
}

class HaltechApp extends StatelessWidget {
  const HaltechApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Haltech Dash',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF080808),
        colorScheme: const ColorScheme.dark(primary: Color(0xFFFF6A00)),
      ),
      home: const DashHome(),
    );
  }
}

// ── CAN Data ──────────────────────────────────────────────────────────────────
class CanData {
  // 0x360
  double rpm = 0;
  double mapKpa = 101.3;
  double tps = 0;
  // 0x362
  double injDuty = 0;
  double ignAngle = 0;
  // 0x364
  double fuelFlow = 0;
  // 0x368
  double lambda = 1.0;
  double lambda2 = 1.0;
  // 0x36A
  double knockLevel = 0;
  double knockCount = 0;
  // 0x372
  double battV = 0;
  double targetBoostKpa = 101.3;
  double baroKpa = 101.3;
  // 0x3E0
  double ect = 0;
  double iat = 0;
  // 0x3E2
  double oilTemp = 0;
  double fuelTemp = 0;
  // 0x3E3
  double stft = 0;
  double ltft = 0;
  // 0x3E4
  int switchByte = 0;
  // 0x470
  int gear = 0;
  // 0x473
  int statusByte = 0;

  double get boostPsi => (mapKpa - baroKpa) * 0.14504;
  double get afr => lambda * 14.7;
  bool get launchActive => (switchByte & 0x01) != 0;
  bool get antilagActive => (statusByte & 0x01) != 0;

  String csvHeader() =>
    'time_ms,rpm,boost_psi,map_kpa,baro_kpa,tps_pct,ect_c,iat_c,oil_temp_c,fuel_temp_c,'
    'afr,lambda,lambda2,ign_deg,inj_duty_pct,fuel_flow,knock_level,knock_count,'
    'stft_pct,ltft_pct,batt_v,target_boost_kpa,gear,switch_byte,status_byte';

  String csvRow(int ms) =>
    '$ms,${rpm.toStringAsFixed(0)},${boostPsi.toStringAsFixed(2)},'
    '${mapKpa.toStringAsFixed(1)},${baroKpa.toStringAsFixed(1)},'
    '${tps.toStringAsFixed(1)},${ect.toStringAsFixed(1)},${iat.toStringAsFixed(1)},'
    '${oilTemp.toStringAsFixed(1)},${fuelTemp.toStringAsFixed(1)},'
    '${afr.toStringAsFixed(2)},${lambda.toStringAsFixed(4)},${lambda2.toStringAsFixed(4)},'
    '${ignAngle.toStringAsFixed(1)},${injDuty.toStringAsFixed(1)},'
    '${fuelFlow.toStringAsFixed(1)},${knockLevel.toStringAsFixed(1)},'
    '${knockCount.toStringAsFixed(0)},${stft.toStringAsFixed(1)},${ltft.toStringAsFixed(1)},'
    '${battV.toStringAsFixed(3)},${targetBoostKpa.toStringAsFixed(1)},$gear,$switchByte,$statusByte';
}

// ── CAN Service ───────────────────────────────────────────────────────────────
class CanService extends ChangeNotifier {
  WebSocketChannel? _channel;
  StreamSubscription? _sub;
  bool connected = false;
  String status = 'DISCONNECTED';
  final CanData data = CanData();
  final List<bool> avi = [false, false];
  Timer? _keepAliveTimer;

  // Logging
  bool logging = false;
  int _logStart = 0;
  final List<String> _logRows = [];
  int frameCount = 0;

  // CAN trace ring buffer (raw SLCAN frames, TX + RX)
  static const int _traceMax = 1000;
  final List<String> _canTrace = [];
  int _traceStart = 0;

  void _trace(String dir, String frame) {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (_traceStart == 0) _traceStart = now;
    if (_canTrace.length >= _traceMax) _canTrace.removeAt(0);
    _canTrace.add('${now - _traceStart} $dir ${frame.replaceAll('\r', '').replaceAll('\n', '')}');
  }

  Future<String> dumpTrace() async {
    final dir = await getApplicationDocumentsDirectory();
    final ts = DateTime.now().toIso8601String().replaceAll(':', '-').substring(0, 19);
    final file = File('${dir.path}/haltech_can_trace_$ts.txt');
    final header = '# Haltech CAN trace - $ts\n# Format: <ms_since_first_frame> <TX|RX> <slcan_frame>\n';
    await file.writeAsString(header + _canTrace.join('\n'));
    return file.path;
  }

  void connect(String ip) {
    disconnect();
    status = 'CONNECTING';
    notifyListeners();
    try {
      _channel = WebSocketChannel.connect(Uri.parse('ws://$ip/ws'));
      _sub = _channel!.stream.listen(
        (msg) {
          if (!connected) {
            connected = true;
            status = 'LIVE';
            _startKeepAlive();
            notifyListeners();
          }
          final s = msg.toString().trim();
          _trace('RX', s);
          _parse(s);
        },
        onError: (_) => _setOff('ERROR'),
        onDone: () => _setOff('DISCONNECTED'),
      );
    } catch (_) {
      _setOff('ERROR');
    }
  }

  void _startKeepAlive() {
    _keepAliveTimer?.cancel();
    _keepAliveTimer = Timer.periodic(const Duration(milliseconds: 100), (_) {
      if (_channel == null || !connected) return;
      const ka = 't2C6510090A0000\r';
      _channel!.sink.add(ka);
      _trace('TX', ka);
      _sendAvi();
    });
  }

  void _setOff(String s) {
    _keepAliveTimer?.cancel(); _keepAliveTimer = null;
    connected = false; status = s;
    avi[0] = false; avi[1] = false;
    notifyListeners();
  }

  void disconnect() {
    _keepAliveTimer?.cancel(); _keepAliveTimer = null;
    _sub?.cancel();
    _channel?.sink.close();
    connected = false; status = 'DISCONNECTED';
    avi[0] = false; avi[1] = false;
    notifyListeners();
  }

  void toggleAvi(int i) {
    avi[i] = !avi[i];
    _sendAvi();
    notifyListeners();
  }

  void _sendAvi() {
    if (_channel == null || !connected) return;
    String h(bool on) => on ? '0FFF' : '0000';
    final frame = 't2C08${h(avi[0])}${h(avi[1])}00000000\r';
    _channel!.sink.add(frame);
    _trace('TX', frame);
  }

  void startLogging() {
    _logRows.clear();
    _logRows.add(data.csvHeader());
    _logStart = DateTime.now().millisecondsSinceEpoch;
    logging = true;
    notifyListeners();
  }

  Future<String> stopLogging() async {
    logging = false;
    notifyListeners();
    final dir = await getApplicationDocumentsDirectory();
    final ts = DateTime.now().toIso8601String().replaceAll(':', '-').substring(0, 19);
    final file = File('${dir.path}/haltech_log_$ts.csv');
    await file.writeAsString(_logRows.join('\n'));
    return file.path;
  }

  void _parse(String msg) {
    if (msg.length < 5) return;
    final isStd = msg[0] == 't';
    final isExt = msg[0] == 'T';
    if (!isStd && !isExt) return;

    final idLen = isExt ? 8 : 3;
    if (msg.length < 2 + idLen) return;

    final id = int.tryParse(msg.substring(1, 1 + idLen), radix: 16);
    final dlc = int.tryParse(msg[1 + idLen]);
    if (id == null || dlc == null) return;

    final ds = 2 + idLen;
    if (msg.length < ds + dlc * 2) return;

    final b = List.generate(
      dlc,
      (i) => int.tryParse(msg.substring(ds + i * 2, ds + i * 2 + 2), radix: 16) ?? 0,
    );

    int u16(int o) => (b[o] << 8) | b[o + 1];
    int s16(int o) { final v = u16(o); return v >= 0x8000 ? v - 0x10000 : v; }

    bool changed = false;
    switch (id) {
      case 0x360:
        data.rpm = u16(0).toDouble();
        data.mapKpa = u16(2) / 10.0;
        data.tps = u16(4) / 10.0;
        frameCount++;
        changed = true;
        break;
      case 0x362:
        data.injDuty = u16(0) / 10.0;
        data.ignAngle = s16(2) / 10.0;
        changed = true;
        break;
      case 0x364:
        data.fuelFlow = u16(0) / 10.0;
        changed = true;
        break;
      case 0x368:
        final r1 = u16(0); final r2 = u16(2);
        if (r1 > 0 && r1 < 2000) data.lambda = r1 / 1000.0;
        if (r2 > 0 && r2 < 2000) data.lambda2 = r2 / 1000.0;
        changed = true;
        break;
      case 0x36A:
        data.knockLevel = u16(0) / 10.0;
        data.knockCount = u16(2).toDouble();
        changed = true;
        break;
      case 0x372:
        data.battV = u16(0) / 1000.0;
        data.targetBoostKpa = u16(4) / 10.0;
        data.baroKpa = u16(6) / 10.0;
        changed = true;
        break;
      case 0x3E0:
        data.ect = s16(0) / 10.0;
        data.iat = s16(2) / 10.0;
        changed = true;
        break;
      case 0x3E2:
        data.oilTemp = s16(0) / 10.0;
        data.fuelTemp = s16(2) / 10.0;
        changed = true;
        break;
      case 0x3E3:
        data.stft = s16(0) / 10.0;
        data.ltft = s16(2) / 10.0;
        changed = true;
        break;
      case 0x3E4:
        data.switchByte = b[0];
        changed = true;
        break;
      case 0x470:
        data.gear = u16(0);
        changed = true;
        break;
      case 0x473:
        data.statusByte = b[4];
        changed = true;
        break;
    }

    if (changed) {
      if (logging) {
        final ms = DateTime.now().millisecondsSinceEpoch - _logStart;
        _logRows.add(data.csvRow(ms));
      }
      notifyListeners();
    }
  }

  @override
  void dispose() { disconnect(); super.dispose(); }
}

// ── Home ──────────────────────────────────────────────────────────────────────
class DashHome extends StatefulWidget {
  const DashHome({super.key});
  @override
  State<DashHome> createState() => _DashHomeState();
}

class _DashHomeState extends State<DashHome> {
  final _svc = CanService();
  final _ipCtrl = TextEditingController(text: '192.168.80.1');
  int _page = 0;

  static const _orange = Color(0xFFFF6A00);
  static const _cyan   = Color(0xFF00B4D8);
  static const _red    = Color(0xFFFF1744);
  static const _green  = Color(0xFF00E676);
  static const _bg     = Color(0xFF080808);
  static const _panel  = Color(0xFF101010);
  static const _border = Color(0xFF1C1C1C);
  static const _dim    = Color(0xFF444444);

  @override
  void dispose() { _svc.dispose(); _ipCtrl.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _svc,
      builder: (ctx, child) => Scaffold(
        backgroundColor: _bg,
        body: SafeArea(
          child: Column(
            children: [
              _header(),
              Expanded(
                child: IndexedStack(
                  index: _page,
                  children: [_dashPage(), _ctrlPage()],
                ),
              ),
              _navBar(),
            ],
          ),
        ),
      ),
    );
  }

  // ── Header ──
  Widget _header() {
    final live = _svc.connected;
    return Container(
      color: _panel,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(
        children: [
          Container(
            width: 8, height: 8,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: live ? _green : _dim,
            ),
          ),
          const SizedBox(width: 8),
          Text(_svc.status,
            style: GoogleFonts.rajdhani(
              fontSize: 13, fontWeight: FontWeight.w600,
              color: live ? _green : const Color(0xFF888888),
            )),
          if (live) ...[
            const SizedBox(width: 8),
            Text('${_svc.frameCount}',
              style: GoogleFonts.rajdhani(fontSize: 11, color: _dim)),
          ],
          const Spacer(),
          SizedBox(
            width: 130, height: 28,
            child: TextField(
              controller: _ipCtrl,
              style: GoogleFonts.rajdhani(fontSize: 12, color: Colors.white70),
              decoration: InputDecoration(
                contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(4),
                  borderSide: const BorderSide(color: Color(0xFF333333)),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(4),
                  borderSide: const BorderSide(color: Color(0xFF333333)),
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          GestureDetector(
            onTap: () => live ? _svc.disconnect() : _svc.connect(_ipCtrl.text.trim()),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: live ? const Color(0xFF1A1A1A) : _orange,
                borderRadius: BorderRadius.circular(4),
                border: Border.all(color: live ? const Color(0xFF444444) : _orange),
              ),
              child: Text(live ? 'DISC' : 'CONN',
                style: GoogleFonts.rajdhani(
                  fontSize: 12, fontWeight: FontWeight.w700,
                  color: live ? const Color(0xFF888888) : Colors.black,
                )),
            ),
          ),
        ],
      ),
    );
  }

  // ── Dash Page ──
  Widget _dashPage() {
    final d = _svc.data;
    return Column(
      children: [
        const SizedBox(height: 8),
        _ShiftLights(rpm: d.rpm),
        Expanded(
          flex: 5,
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: AspectRatio(
                aspectRatio: 1,
                child: CustomPaint(
                  painter: _TachPainter(rpm: d.rpm),
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(d.rpm.toInt().toString(),
                          style: GoogleFonts.orbitron(
                            fontSize: 50, fontWeight: FontWeight.w900,
                            color: Colors.white,
                          )),
                        Text('RPM',
                          style: GoogleFonts.rajdhani(
                            fontSize: 14, fontWeight: FontWeight.w600,
                            color: _dim, letterSpacing: 4,
                          )),
                        const SizedBox(height: 4),
                        Text('GEAR ${d.gear > 0 ? d.gear : "-"}',
                          style: GoogleFonts.orbitron(
                            fontSize: 18, fontWeight: FontWeight.w700,
                            color: _orange,
                          )),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
        // Row 1: main gauges
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10),
          child: Row(
            children: [
              _mini('BOOST', d.boostPsi.toStringAsFixed(1), 'psi', _boostColor(d.boostPsi)),
              _mini('ECT',   '${d.ect.toInt()}',            '°C',  _ectColor(d.ect)),
              _mini('IAT',   '${d.iat.toInt()}',            '°C',  Colors.white70),
              _mini('AFR',   d.afr.toStringAsFixed(1),      '',    _afrColor(d.afr)),
              _mini('IGN',   d.ignAngle.toStringAsFixed(1), '°',   Colors.white70),
              _mini('TPS',   '${d.tps.toInt()}',            '%',   Colors.white70),
            ],
          ),
        ),
        const SizedBox(height: 6),
        // Row 2: secondary gauges
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
          child: Row(
            children: [
              _mini('OIL',  d.oilTemp.toInt().toString(),    '°C',  _ectColor(d.oilTemp)),
              _mini('FUEL', d.fuelTemp.toInt().toString(),   '°C',  Colors.white70),
              _mini('STFT', d.stft.toStringAsFixed(1), '%',   _corrColor(d.stft)),
              _mini('LTFT', d.ltft.toStringAsFixed(1), '%',   _corrColor(d.ltft)),
              _mini('KNOCK', d.knockLevel.toStringAsFixed(1), '', _knockColor(d.knockLevel)),
              _mini('BATT', d.battV.toStringAsFixed(1),     'V',   Colors.white70),
            ],
          ),
        ),
      ],
    );
  }

  Widget _mini(String label, String val, String unit, Color col) {
    return Expanded(
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 2),
        padding: const EdgeInsets.symmetric(vertical: 6),
        decoration: BoxDecoration(
          color: _panel,
          borderRadius: BorderRadius.circular(5),
          border: Border.all(color: _border),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(label,
              style: GoogleFonts.rajdhani(
                fontSize: 9, fontWeight: FontWeight.w600,
                color: _dim, letterSpacing: 1,
              )),
            const SizedBox(height: 1),
            Text(val,
              style: GoogleFonts.orbitron(
                fontSize: 13, fontWeight: FontWeight.w700, color: col,
              )),
            if (unit.isNotEmpty)
              Text(unit, style: GoogleFonts.rajdhani(fontSize: 8, color: const Color(0xFF333333))),
          ],
        ),
      ),
    );
  }

  // ── Control Page ──
  Widget _ctrlPage() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('CONTROLS',
            style: GoogleFonts.orbitron(
              fontSize: 13, fontWeight: FontWeight.w700,
              color: _dim, letterSpacing: 4,
            )),
          const SizedBox(height: 20),
          Row(
            children: [
              Expanded(child: _aviBtn(0, 'LAUNCH\nCONTROL', _orange)),
              const SizedBox(width: 16),
              Expanded(child: _aviBtn(1, 'ANTI\nLAG', _cyan)),
            ],
          ),
          const SizedBox(height: 24),
          Text('LOGGING',
            style: GoogleFonts.orbitron(
              fontSize: 13, fontWeight: FontWeight.w700,
              color: _dim, letterSpacing: 4,
            )),
          const SizedBox(height: 12),
          _logButton(),
          const SizedBox(height: 24),
          Text('DEBUG',
            style: GoogleFonts.orbitron(
              fontSize: 13, fontWeight: FontWeight.w700,
              color: _dim, letterSpacing: 4,
            )),
          const SizedBox(height: 12),
          _dumpTraceButton(),
          const SizedBox(height: 24),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: _panel, borderRadius: BorderRadius.circular(8),
              border: Border.all(color: _border),
            ),
            child: Text(
              'NSP setup:\nFunctions → CAN → IO Box\nAVI1 → Launch Control Switch\nAVI2 → Anti-Lag Switch',
              style: GoogleFonts.rajdhani(fontSize: 12, color: _dim, height: 1.6),
            ),
          ),
        ],
      ),
    );
  }

  Widget _dumpTraceButton() {
    return GestureDetector(
      onTap: () async {
        final path = await _svc.dumpTrace();
        if (!mounted) return;
        await SharePlus.instance.share(
          ShareParams(files: [XFile(path)], subject: 'Haltech CAN Trace'),
        );
      },
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 14),
        decoration: BoxDecoration(
          color: _panel,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: _border),
        ),
        child: Column(
          children: [
            Icon(Icons.bug_report, color: _dim, size: 24),
            const SizedBox(height: 4),
            Text('DUMP CAN TRACE',
              style: GoogleFonts.orbitron(
                fontSize: 12, fontWeight: FontWeight.w900,
                color: _dim, letterSpacing: 2,
              )),
          ],
        ),
      ),
    );
  }

  Widget _aviBtn(int i, String label, Color col) {
    final on = _svc.avi[i];
    return GestureDetector(
      onTap: () => _svc.toggleAvi(i),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        height: 110,
        decoration: BoxDecoration(
          color: on ? col.withValues(alpha: 0.12) : _panel,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: on ? col : _border, width: on ? 2 : 1),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(label,
              textAlign: TextAlign.center,
              style: GoogleFonts.orbitron(
                fontSize: 16, fontWeight: FontWeight.w900,
                color: on ? col : _dim, height: 1.3,
              )),
            const SizedBox(height: 8),
            Text(on ? 'ON' : 'OFF',
              style: GoogleFonts.rajdhani(
                fontSize: 12, fontWeight: FontWeight.w700,
                color: on ? col : const Color(0xFF333333), letterSpacing: 3,
              )),
          ],
        ),
      ),
    );
  }

  Widget _logButton() {
    final logging = _svc.logging;
    return GestureDetector(
      onTap: () async {
        if (!_svc.connected) return;
        if (logging) {
          final path = await _svc.stopLogging();
          if (!mounted) return;
          await SharePlus.instance.share(ShareParams(files: [XFile(path)], subject: 'Haltech Log'));
        } else {
          _svc.startLogging();
        }
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 18),
        decoration: BoxDecoration(
          color: logging ? _red.withValues(alpha: 0.12) : _panel,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: logging ? _red : _border, width: logging ? 2 : 1),
        ),
        child: Column(
          children: [
            Icon(logging ? Icons.stop_circle : Icons.fiber_manual_record,
              color: logging ? _red : _dim, size: 28),
            const SizedBox(height: 6),
            Text(logging ? 'STOP & EXPORT' : 'START LOG',
              style: GoogleFonts.orbitron(
                fontSize: 14, fontWeight: FontWeight.w900,
                color: logging ? _red : _dim, letterSpacing: 2,
              )),
            if (logging) ...[
              const SizedBox(height: 4),
              Text('${_svc._logRows.length} rows',
                style: GoogleFonts.rajdhani(fontSize: 11, color: _red)),
            ],
          ],
        ),
      ),
    );
  }

  // ── Nav Bar ──
  Widget _navBar() {
    return Container(
      color: _panel,
      child: Row(
        children: [
          _navTab(0, 'DASH', Icons.speed),
          _navTab(1, 'CTRL', Icons.tune),
        ],
      ),
    );
  }

  Widget _navTab(int idx, String lbl, IconData icon) {
    final active = _page == idx;
    return Expanded(
      child: GestureDetector(
        onTap: () => setState(() => _page = idx),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 12),
          decoration: BoxDecoration(
            border: Border(top: BorderSide(
              color: active ? _orange : Colors.transparent, width: 2,
            )),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 20, color: active ? _orange : _dim),
              const SizedBox(height: 2),
              Text(lbl,
                style: GoogleFonts.rajdhani(
                  fontSize: 11, fontWeight: FontWeight.w600,
                  color: active ? _orange : _dim, letterSpacing: 2,
                )),
            ],
          ),
        ),
      ),
    );
  }

  // ── Colours ──
  Color _boostColor(double psi) {
    if (psi > 13) return _red;
    if (psi > 10) return _orange;
    return _green;
  }
  Color _ectColor(double c) {
    if (c > 95) return _red;
    if (c > 85) return const Color(0xFFFFB300);
    return Colors.white70;
  }
  Color _afrColor(double afr) {
    if (afr < 12.0) return _red;
    if (afr > 16.5) return const Color(0xFFFFB300);
    if (afr >= 14.2 && afr <= 15.2) return _green;
    return Colors.white70;
  }
  Color _corrColor(double pct) {
    if (pct.abs() > 15) return _red;
    if (pct.abs() > 8) return const Color(0xFFFFB300);
    return Colors.white70;
  }
  Color _knockColor(double k) {
    if (k > 5) return _red;
    if (k > 2) return const Color(0xFFFFB300);
    return _green;
  }
}

// ── Shift Lights ──────────────────────────────────────────────────────────────
class _ShiftLights extends StatelessWidget {
  final double rpm;
  const _ShiftLights({required this.rpm});

  static const _thresholds = [
    4000, 4200, 4400, 4600, 4800, 5000, 5200,
    5500, 5800, 6000, 6100, 6200, 6350, 6500,
  ];
  static const _colors = [
    Color(0xFF00E676), Color(0xFF00E676), Color(0xFF00E676), Color(0xFF00E676),
    Color(0xFF00E676), Color(0xFF00E676), Color(0xFF00E676),
    Color(0xFFFFB300), Color(0xFFFFB300), Color(0xFFFFB300),
    Color(0xFFFF1744), Color(0xFFFF1744), Color(0xFFFF1744), Color(0xFFFF1744),
  ];

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: List.generate(_thresholds.length, (i) {
        final on = rpm >= _thresholds[i];
        return Container(
          width: 18, height: 8,
          margin: const EdgeInsets.symmetric(horizontal: 2),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(2),
            color: on ? _colors[i] : const Color(0xFF1A1A1A),
            boxShadow: on
              ? [BoxShadow(color: _colors[i].withValues(alpha: 0.6), blurRadius: 6)]
              : null,
          ),
        );
      }),
    );
  }
}

// ── Arc Tachometer ────────────────────────────────────────────────────────────
class _TachPainter extends CustomPainter {
  final double rpm;
  static const _maxRpm   = 8000.0;
  static const _redline  = 6500.0;
  static const _startDeg = 225.0;
  static const _sweepDeg = 270.0;

  const _TachPainter({required this.rpm});

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final cy = size.height / 2;
    final r  = size.width * 0.44;

    canvas.drawArc(
      Rect.fromCircle(center: Offset(cx, cy), radius: r),
      _rad(_startDeg), _rad(_sweepDeg), false,
      Paint()
        ..color = const Color(0xFF1A1A1A)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 14
        ..strokeCap = StrokeCap.round,
    );

    final frac = (rpm / _maxRpm).clamp(0.0, 1.0);
    final sweep = _rad(_sweepDeg * frac);
    if (sweep > 0) {
      final col = rpm >= _redline
          ? const Color(0xFFFF1744)
          : rpm >= 5500
              ? const Color(0xFFFF6A00)
              : const Color(0xFF00B4D8);
      canvas.drawArc(
        Rect.fromCircle(center: Offset(cx, cy), radius: r),
        _rad(_startDeg), sweep, false,
        Paint()
          ..color = col
          ..style = PaintingStyle.stroke
          ..strokeWidth = 14
          ..strokeCap = StrokeCap.round,
      );
    }

    final tp = Paint()..color = const Color(0xFF2A2A2A)..strokeWidth = 1.5;
    for (int i = 0; i <= 8; i++) {
      final a = _rad(_startDeg + _sweepDeg * (i / 8.0));
      canvas.drawLine(
        Offset(cx + (r - 16) * math.cos(a), cy + (r - 16) * math.sin(a)),
        Offset(cx + (r +  2) * math.cos(a), cy + (r +  2) * math.sin(a)),
        tp,
      );
    }
  }

  double _rad(double deg) => deg * math.pi / 180;

  @override
  bool shouldRepaint(_TachPainter old) => old.rpm != rpm;
}
