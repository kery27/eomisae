import 'package:eomisae_prototype/wait_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('hm은 시:분:초를 두 자리로 맞춘다', () {
    expect(hm(DateTime(2026, 9, 28, 8, 5, 3)), '08:05:03');
  });

  test('ActiveWait.minutes는 시작 후 흐른 분을 센다', () {
    final w = ActiveWait(
        '바삭치킨', DateTime.now().subtract(const Duration(minutes: 12, seconds: 30)));
    expect(w.minutes, 12);
  });
}
