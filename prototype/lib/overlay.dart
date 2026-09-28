import 'dart:async';

import 'package:flutter/material.dart';
import 'package:system_alert_window/system_alert_window.dart';

import 'wait_store.dart';

/// 다른 앱(유튜브 등) 위에 떠 있는 타이머. 앱 본체와 다른 Flutter 엔진에서 돈다.
/// 대기 상태는 저장소를 1초마다 읽어서 보여주고, [픽업]·[취소]는
/// 요청만 남긴다(처리는 타이머 서비스가 함). 시제품 확인 3.
class WaitOverlay extends StatefulWidget {
  const WaitOverlay({super.key});

  @override
  State<WaitOverlay> createState() => _WaitOverlayState();
}

class _WaitOverlayState extends State<WaitOverlay> {
  ActiveWait? _wait;
  bool _expanded = false;
  bool _requested = false;
  bool _sawWait = false;
  String? _doneText;
  Timer? _poll;
  Timer? _collapse;

  @override
  void initState() {
    super.initState();
    _poll = Timer.periodic(const Duration(seconds: 1), (_) => _refresh());
    _refresh();
  }

  Future<void> _refresh() async {
    final w = await WaitStore.loadWait();
    if (!mounted) return;
    if (w != null) _sawWait = true;
    if (w == null && _sawWait && _doneText == null) {
      // 서비스가 요청을 처리해서 대기가 끝났다 → 잠깐 보여주고 닫기
      setState(() => _doneText = _requested ? '기록됨' : '앱에서 끝남');
      Future.delayed(const Duration(seconds: 2), _close);
      return;
    }
    setState(() => _wait = w);
  }

  void _close() {
    SystemAlertWindow.closeSystemWindow(prefMode: SystemWindowPrefMode.OVERLAY);
  }

  void _toggle() {
    setState(() => _expanded = !_expanded);
    _collapse?.cancel();
    if (_expanded) {
      _collapse = Timer(const Duration(seconds: 5), () {
        if (mounted) setState(() => _expanded = false);
      });
    }
  }

  Future<void> _request(String action) async {
    _collapse?.cancel();
    setState(() => _requested = true);
    await WaitStore.requestAction(action, 'overlay');
  }

  Color _color(int m) {
    if (m >= 20) return const Color(0xFF8F1D3A);
    if (m >= 10) return const Color(0xFFC2410C);
    return const Color(0xFF5B6470);
  }

  @override
  void dispose() {
    _poll?.cancel();
    _collapse?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final w = _wait;
    final m = w?.minutes ?? 0;
    final label = _doneText ?? (w == null ? '대기 없음' : '대기 $m분');
    return Material(
      color: Colors.transparent,
      child: Align(
        alignment: Alignment.topRight,
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: _expanded && w != null && _doneText == null
              ? _card(w, m)
              : _pill(label, w == null ? const Color(0xFF1F4E8C) : _color(m)),
        ),
      ),
    );
  }

  Widget _pill(String label, Color color) => GestureDetector(
        onTap: _toggle,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(22),
            border: Border.all(color: Colors.white, width: 2),
          ),
          child: Text(label,
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.bold)),
        ),
      );

  Widget _card(ActiveWait w, int m) => Container(
        width: 210,
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          boxShadow: const [BoxShadow(blurRadius: 8, color: Colors.black38)],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('${w.store} · 대기 $m분',
                style: const TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            if (_requested)
              const Text('요청 보냄, 처리 기다리는 중…')
            else
              Row(children: [
                Expanded(
                  child: FilledButton(
                      onPressed: () => _request('pickup'),
                      child: const Text('픽업')),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: OutlinedButton(
                      onPressed: () => _request('cancel'),
                      child: const Text('취소')),
                ),
              ]),
          ],
        ),
      );
}
