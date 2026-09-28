import 'dart:async';
import 'dart:convert';

import 'package:activity_recognition_flutter/activity_recognition_flutter.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:system_alert_window/system_alert_window.dart';

import 'overlay.dart';
import 'timer_task.dart';
import 'wait_store.dart';

void main() {
  FlutterForegroundTask.initCommunicationPort();
  runApp(const PrototypeApp());
}

/// 떠 있는 창의 진입점. system_alert_window가 별도 엔진에서 이 함수를 실행한다.
@pragma('vm:entry-point')
void overlayMain() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MaterialApp(
    debugShowCheckedModeBanner: false,
    home: WaitOverlay(),
  ));
}

class PrototypeApp extends StatelessWidget {
  const PrototypeApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '어미새 시제품',
      theme: ThemeData(colorSchemeSeed: const Color(0xFF1F4E8C)),
      home: const WithForegroundTask(child: HomePage()),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final _storeCtl = TextEditingController(text: '바삭치킨 ○○점');
  ActiveWait? _wait;
  bool _serviceRunning = false;
  List<Map<String, dynamic>> _visits = [];
  List<Map<String, dynamic>> _gaps = [];
  List<Map<String, dynamic>> _acts = [];
  StreamSubscription<ActivityEvent>? _actSub;
  String _currentAct = '-';
  Timer? _refreshTimer;
  final Map<String, bool> _perm = {};

  @override
  void initState() {
    super.initState();
    FlutterForegroundTask.addTaskDataCallback(_onTaskData);
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'wait_timer',
        channelName: '대기 타이머',
        channelDescription: '가게 앞 대기 시간을 보여줍니다',
        onlyAlertOnce: true,
      ),
      iosNotificationOptions: const IOSNotificationOptions(),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.repeat(1000),
        autoRunOnBoot: false,
        allowWakeLock: true,
      ),
    );
    _refreshTimer =
        Timer.periodic(const Duration(seconds: 1), (_) => _refresh());
    _refresh();
    _checkPermissions();
  }

  @override
  void dispose() {
    FlutterForegroundTask.removeTaskDataCallback(_onTaskData);
    _refreshTimer?.cancel();
    _actSub?.cancel();
    super.dispose();
  }

  void _onTaskData(Object data) => _refresh();

  Future<void> _refresh() async {
    final wait = await WaitStore.loadWait();
    final running = await FlutterForegroundTask.isRunningService;
    final visits = await WaitStore.visitLog();
    final gaps = await WaitStore.gapLog();
    final acts = await WaitStore.activityLog();
    if (!mounted) return;
    setState(() {
      _wait = wait;
      _serviceRunning = running;
      _visits = visits;
      _gaps = gaps;
      _acts = acts;
    });
  }

  // ---------------- 권한 ----------------

  Future<void> _checkPermissions() async {
    final noti = await FlutterForegroundTask.checkNotificationPermission();
    final overlay = await SystemAlertWindow.checkPermissions(
            prefMode: SystemWindowPrefMode.OVERLAY) ??
        false;
    final act = await Permission.activityRecognition.isGranted;
    final battery = await FlutterForegroundTask.isIgnoringBatteryOptimizations;
    if (!mounted) return;
    setState(() {
      _perm['알림'] = noti == NotificationPermission.granted;
      _perm['다른 앱 위에 표시'] = overlay;
      _perm['신체 활동'] = act;
      _perm['배터리 최적화 제외'] = battery;
    });
  }

  Future<void> _requestPermission(String name) async {
    switch (name) {
      case '알림':
        await FlutterForegroundTask.requestNotificationPermission();
      case '다른 앱 위에 표시':
        await SystemAlertWindow.requestPermissions(
            prefMode: SystemWindowPrefMode.OVERLAY);
      case '신체 활동':
        await Permission.activityRecognition.request();
      case '배터리 최적화 제외':
        await FlutterForegroundTask.requestIgnoreBatteryOptimization();
    }
    await _checkPermissions();
  }

  // ---------------- 대기 ----------------

  Future<void> _startWait() async {
    final store = _storeCtl.text.trim().isEmpty ? '테스트 가게' : _storeCtl.text.trim();
    await WaitStore.startWait(store);
    final result = await FlutterForegroundTask.startService(
      serviceId: 700,
      serviceTypes: [ForegroundServiceTypes.specialUse],
      notificationTitle: '$store 대기 0분',
      notificationText: '시작',
      notificationButtons: const [
        NotificationButton(id: 'pickup', text: '픽업'),
        NotificationButton(id: 'cancel', text: '취소'),
      ],
      notificationInitialRoute: '/',
      callback: startTimerCallback,
    );
    if (result is ServiceRequestFailure) {
      _toast('서비스 시작 실패: ${result.error}');
    }
    await _showOverlay();
    await _refresh();
  }

  Future<void> _showOverlay() async {
    if (_perm['다른 앱 위에 표시'] != true) return;
    await SystemAlertWindow.showSystemWindow(
      gravity: SystemWindowGravity.TOP,
      width: 240,
      height: 140,
      notificationTitle: '대기 타이머',
      notificationBody: '떠 있는 타이머',
      prefMode: SystemWindowPrefMode.OVERLAY,
    );
  }

  Future<void> _endFromApp(String action) async {
    if (await FlutterForegroundTask.isRunningService) {
      // 원칙대로 요청만 남기고 서비스가 처리
      await WaitStore.requestAction(action, 'app');
    } else {
      // 서비스가 죽어 있는 상황 자체가 확인 대상이므로 기록에 남긴다
      await WaitStore.finishWait(action, 'app(서비스 꺼짐)', DateTime.now());
      _toast('타이머 서비스가 꺼져 있었습니다. 기록에 표시됨');
    }
    await _refresh();
  }

  // ---------------- 활동 인식 ----------------

  Future<void> _toggleActivity() async {
    if (_actSub != null) {
      await _actSub!.cancel();
      setState(() {
        _actSub = null;
        _currentAct = '-';
      });
      return;
    }
    if (!await Permission.activityRecognition.request().isGranted) {
      _toast('신체 활동 권한이 필요합니다');
      return;
    }
    String? last;
    final sub = ActivityRecognition()
        .activityStream(runForegroundService: true)
        .listen((e) {
      setState(() => _currentAct = '${e.typeString} (${e.confidence}%)');
      // 바뀔 때만 기록해서 로그를 짧게 유지
      if (e.typeString != last) {
        last = e.typeString;
        WaitStore.addActivity(e.typeString, e.confidence);
      }
    }, onError: (Object err) => _toast('활동 인식 오류: $err'));
    setState(() => _actSub = sub);
  }

  // ---------------- 결과 ----------------

  Future<void> _copyLogs() async {
    final text = const JsonEncoder.withIndent(' ').convert({
      'visits': _visits,
      'service_gaps': _gaps,
      'activities': _acts,
    });
    await Clipboard.setData(ClipboardData(text: text));
    _toast('기록을 복사했습니다. 카톡 등에 붙여넣어 공유하세요');
  }

  Future<void> _clearLogs() async {
    await WaitStore.clearLogs();
    await _refresh();
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  String _t(int ms) => hm(DateTime.fromMillisecondsSinceEpoch(ms));

  @override
  Widget build(BuildContext context) {
    final w = _wait;
    return Scaffold(
      appBar: AppBar(title: const Text('어미새 시제품 (1.5단계)')),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _section('1. 권한'),
            for (final e in _perm.entries)
              ListTile(
                dense: true,
                title: Text(e.key),
                trailing: e.value
                    ? const Text('허용됨')
                    : TextButton(
                        onPressed: () => _requestPermission(e.key),
                        child: const Text('허용하기')),
              ),
            const Divider(),
            _section('2. 대기 타이머'),
            Text('타이머 서비스: ${_serviceRunning ? '실행 중' : '꺼짐'}'),
            const SizedBox(height: 8),
            if (w == null) ...[
              TextField(
                controller: _storeCtl,
                decoration: const InputDecoration(labelText: '가게 이름 (아무거나)'),
              ),
              const SizedBox(height: 8),
              FilledButton(
                  onPressed: _startWait, child: const Text('대기 시작')),
            ] else ...[
              Text('${w.store} · 대기 ${w.minutes}분 · 도착 ${hm(w.start)}',
                  style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              Row(children: [
                Expanded(
                    child: FilledButton(
                        onPressed: () => _endFromApp('pickup'),
                        child: const Text('픽업'))),
                const SizedBox(width: 8),
                Expanded(
                    child: OutlinedButton(
                        onPressed: () => _endFromApp('cancel'),
                        child: const Text('취소'))),
              ]),
              TextButton(
                  onPressed: _showOverlay,
                  child: const Text('떠 있는 타이머 다시 띄우기')),
            ],
            const Divider(),
            _section('3. 활동 인식'),
            Text('지금: $_currentAct'),
            FilledButton.tonal(
                onPressed: _toggleActivity,
                child: Text(_actSub == null ? '기록 시작' : '기록 중지')),
            const Divider(),
            _section('4. 결과'),
            Row(children: [
              TextButton(onPressed: _copyLogs, child: const Text('전체 복사')),
              TextButton(onPressed: _clearLogs, child: const Text('지우기')),
            ]),
            Text('대기 기록 ${_visits.length}건',
                style: const TextStyle(fontWeight: FontWeight.bold)),
            for (final v in _visits.take(20))
              Text('${v['store']} ${_t(v['start'] as int)}→${_t(v['end'] as int)} '
                  '${v['result']} · ${v['via']} · 처리 지연 ${v['applied_delay_s']}초'),
            const SizedBox(height: 8),
            Text('서비스 멈춤 ${_gaps.length}건 (5초 넘게 박동 없음)',
                style: const TextStyle(fontWeight: FontWeight.bold)),
            for (final g in _gaps.take(20))
              Text('${_t(g['from'] as int)} ~ ${_t(g['to'] as int)} '
                  '(${((g['to'] as int) - (g['from'] as int)) ~/ 1000}초)'),
            const SizedBox(height: 8),
            Text('활동 변화 ${_acts.length}건',
                style: const TextStyle(fontWeight: FontWeight.bold)),
            for (final a in _acts.take(30))
              Text('${_t(a['at'] as int)} ${a['type']} ${a['confidence']}%'),
          ],
        ),
      ),
    );
  }

  Widget _section(String title) => Padding(
        padding: const EdgeInsets.only(top: 8, bottom: 4),
        child: Text(title, style: Theme.of(context).textTheme.titleLarge),
      );
}
