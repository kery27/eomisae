import 'dart:convert';

import 'package:flutter_foreground_task/flutter_foreground_task.dart';

/// 앱 화면, 타이머 서비스(TaskHandler), 떠 있는 창(오버레이) 세 곳이
/// 함께 보는 대기 상태.
///
/// 원칙: 상태의 원본은 이 저장소 하나다. 대기를 "끝내는" 것(픽업·취소 적용)은
/// 타이머 서비스만 한다. 앱 화면과 오버레이는 [requestAction]으로 요청만 남기고,
/// 서비스가 1초마다 그 요청을 읽어 처리한다. 서비스가 꺼져 있을 때만
/// 앱 화면이 직접 처리한다(시제품에서 그 상황 자체가 확인 대상).
class WaitStore {
  static const _kStartMs = 'wait_start_ms';
  static const _kStore = 'wait_store';
  static const _kPending = 'pending_action';
  static const _kVisitLog = 'visit_log';
  static const _kActivityLog = 'activity_log';
  static const _kHeartbeat = 'task_heartbeat_ms';
  static const _kGapLog = 'task_gap_log';

  static Future<ActiveWait?> loadWait() async {
    final start = await FlutterForegroundTask.getData<int>(key: _kStartMs);
    final store = await FlutterForegroundTask.getData<String>(key: _kStore);
    if (start == null || store == null) return null;
    return ActiveWait(store, DateTime.fromMillisecondsSinceEpoch(start));
  }

  static Future<void> startWait(String store) async {
    await FlutterForegroundTask.removeData(key: _kPending);
    await FlutterForegroundTask.saveData(key: _kStore, value: store);
    await FlutterForegroundTask.saveData(
        key: _kStartMs, value: DateTime.now().millisecondsSinceEpoch);
  }

  /// 앱 화면이나 오버레이가 "픽업/취소해 주세요"라고 요청만 남긴다.
  static Future<void> requestAction(String action, String via) async {
    await FlutterForegroundTask.saveData(
      key: _kPending,
      value: jsonEncode({
        'action': action,
        'via': via,
        'at': DateTime.now().millisecondsSinceEpoch,
      }),
    );
  }

  static Future<PendingAction?> takePending() async {
    final raw = await FlutterForegroundTask.getData<String>(key: _kPending);
    if (raw == null) return null;
    await FlutterForegroundTask.removeData(key: _kPending);
    final m = jsonDecode(raw) as Map<String, dynamic>;
    return PendingAction(m['action'] as String, m['via'] as String,
        DateTime.fromMillisecondsSinceEpoch(m['at'] as int));
  }

  /// 대기를 끝내고 기록을 남긴다. 기록 시각은 요청이 들어온 시각을 쓴다.
  static Future<Map<String, dynamic>?> finishWait(
      String action, String via, DateTime at) async {
    final wait = await loadWait();
    if (wait == null) return null;
    final entry = {
      'store': wait.store,
      'start': wait.start.millisecondsSinceEpoch,
      'end': at.millisecondsSinceEpoch,
      'result': action,
      'via': via,
      // 요청을 남긴 뒤 서비스가 실제로 처리하기까지 걸린 시간(초)
      'applied_delay_s':
          DateTime.now().difference(at).inMilliseconds / 1000.0,
    };
    await appendLog(_kVisitLog, entry);
    await FlutterForegroundTask.removeData(key: _kStartMs);
    await FlutterForegroundTask.removeData(key: _kStore);
    return entry;
  }

  static Future<List<Map<String, dynamic>>> visitLog() => _loadLog(_kVisitLog);
  static Future<List<Map<String, dynamic>>> activityLog() =>
      _loadLog(_kActivityLog);
  static Future<List<Map<String, dynamic>>> gapLog() => _loadLog(_kGapLog);

  static Future<void> addActivity(String type, int confidence) =>
      appendLog(_kActivityLog, {
        'at': DateTime.now().millisecondsSinceEpoch,
        'type': type,
        'confidence': confidence,
      });

  /// 타이머 서비스가 1초마다 호출. 직전 박동과 5초 넘게 벌어지면
  /// "서비스가 멈춰 있었다"는 뜻이므로 기록해 둔다(절전 기능 확인용).
  static Future<void> heartbeat() async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final last = await FlutterForegroundTask.getData<int>(key: _kHeartbeat);
    if (last != null && now - last > 5000) {
      await appendLog(_kGapLog, {'from': last, 'to': now});
    }
    await FlutterForegroundTask.saveData(key: _kHeartbeat, value: now);
  }

  static Future<void> resetHeartbeat() =>
      FlutterForegroundTask.removeData(key: _kHeartbeat);

  static Future<void> clearLogs() async {
    for (final k in [_kVisitLog, _kActivityLog, _kGapLog]) {
      await FlutterForegroundTask.removeData(key: k);
    }
  }

  static Future<void> appendLog(String key, Map<String, dynamic> entry,
      {int max = 300}) async {
    final list = await _loadLog(key);
    list.insert(0, entry);
    if (list.length > max) list.removeRange(max, list.length);
    await FlutterForegroundTask.saveData(key: key, value: jsonEncode(list));
  }

  static Future<List<Map<String, dynamic>>> _loadLog(String key) async {
    final raw = await FlutterForegroundTask.getData<String>(key: key);
    if (raw == null) return [];
    return (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
  }
}

class ActiveWait {
  ActiveWait(this.store, this.start);
  final String store;
  final DateTime start;

  int get minutes => DateTime.now().difference(start).inMinutes;
}

class PendingAction {
  PendingAction(this.action, this.via, this.at);
  final String action;
  final String via;
  final DateTime at;
}

String hm(DateTime t) =>
    '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}:${t.second.toString().padLeft(2, '0')}';
