import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import 'wait_store.dart';

/// 포그라운드 서비스 안에서 도는 대기 타이머.
/// 앱 화면이 꺼져 있어도 살아 있어야 한다(시제품 확인 1).
@pragma('vm:entry-point')
void startTimerCallback() {
  FlutterForegroundTask.setTaskHandler(WaitTimerHandler());
}

class WaitTimerHandler extends TaskHandler {
  int _lastShownMinute = -1;
  bool _busy = false;

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    await WaitStore.resetHeartbeat();
    await _tick();
  }

  @override
  void onRepeatEvent(DateTime timestamp) {
    _tick();
  }

  Future<void> _tick() async {
    if (_busy) return;
    _busy = true;
    try {
      await WaitStore.heartbeat();

      // 앱 화면·오버레이가 남긴 요청 처리 (시제품 확인 3)
      final pending = await WaitStore.takePending();
      if (pending != null) {
        await _finish(pending.action, pending.via, pending.at);
        return;
      }

      final wait = await WaitStore.loadWait();
      if (wait == null) {
        await FlutterForegroundTask.stopService();
        return;
      }
      final m = wait.minutes;
      if (m != _lastShownMinute) {
        _lastShownMinute = m;
        await FlutterForegroundTask.updateService(
          notificationTitle: '${wait.store} 대기 $m분',
          notificationText: '도착 ${hm(wait.start)}',
        );
      }
      FlutterForegroundTask.sendDataToMain({'type': 'tick', 'minutes': m});
    } finally {
      _busy = false;
    }
  }

  // 알림창의 [픽업]·[취소] (시제품 확인 2: 앱이 꺼져 있어도 기록되는가)
  @override
  void onNotificationButtonPressed(String id) {
    _finish(id, 'notification', DateTime.now());
  }

  @override
  void onNotificationPressed() {
    FlutterForegroundTask.launchApp('/');
  }

  Future<void> _finish(String action, String via, DateTime at) async {
    final entry = await WaitStore.finishWait(action, via, at);
    FlutterForegroundTask.sendDataToMain({'type': 'finished', 'entry': entry});
    await FlutterForegroundTask.stopService();
  }

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {}

  @override
  void onReceiveData(Object data) {}
}
