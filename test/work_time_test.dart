import 'package:flutter_test/flutter_test.dart';
import 'package:mis_horas/domain/work_time.dart';

void main() {
  group('cálculo de jornada', () {
    test('resta la pausa al tramo trabajado', () {
      const movement = WorkMovement(
        id: null,
        date: '2026-11-16',
        accountId: 1,
        startMinute: 9 * 60,
        endMinute: 17 * 60,
        breakMinutes: 30,
        crossesMidnight: false,
      );

      expect(movement.workedMinutes, 450);
      expect(formatMinutes(movement.workedMinutes), '7h 30');
    });

    test('calcula correctamente un tramo que cruza medianoche', () {
      const movement = WorkMovement(
        id: null,
        date: '2026-11-16',
        accountId: 1,
        startMinute: 22 * 60,
        endMinute: 6 * 60,
        breakMinutes: 30,
        crossesMidnight: true,
      );

      expect(movement.workedMinutes, 450);
    });
  });

  test('la semana laboral de ejemplo suma 40 horas', () {
    final monday = DateTime(2026, 11, 16);
    expect(weeklyTarget(monday, [480, 480, 480, 480, 480, 0, 0]), 2400);
  });

  group('tiempo médico', () {
    test('reduce el objetivo sin cambiar las horas trabajadas', () {
      expect(targetAfterMedical(480, 60), 420);
    });

    test(
      'el tiempo médico no puede reducir el objetivo por debajo de cero',
      () {
        expect(targetAfterMedical(480, 600), 0);
      },
    );

    test('asunto propio y médico son estados de día reconocidos', () {
      expect(DayKind.personal.label, 'Asunto propio');
      expect(DayKind.medical.label, 'Médico');
    });
  });
}
