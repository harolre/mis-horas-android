class WorkMovement {
  const WorkMovement({
    required this.id,
    required this.date,
    required this.accountId,
    required this.startMinute,
    required this.endMinute,
    required this.breakMinutes,
    required this.crossesMidnight,
  });

  final int? id;
  final String date;
  final int accountId;
  final int startMinute;
  final int endMinute;
  final int breakMinutes;
  final bool crossesMidnight;

  int get workedMinutes =>
      endMinute - startMinute + (crossesMidnight ? 1440 : 0) - breakMinutes;

  Map<String, Object?> toMap() => {
        'id': id,
        'date': date,
        'account_id': accountId,
        'start_minute': startMinute,
        'end_minute': endMinute,
        'break_minutes': breakMinutes,
        'crosses_midnight': crossesMidnight ? 1 : 0,
      };

  factory WorkMovement.fromMap(Map<String, Object?> map) => WorkMovement(
        id: map['id'] as int?,
        date: map['date'] as String,
        accountId: map['account_id'] as int,
        startMinute: map['start_minute'] as int,
        endMinute: map['end_minute'] as int,
        breakMinutes: map['break_minutes'] as int,
        crossesMidnight: map['crosses_midnight'] == 1,
      );
}

enum DayKind { work, vacation, holiday, sick }

extension DayKindLabel on DayKind {
  String get label => switch (this) {
        DayKind.work => 'Trabajo',
        DayKind.vacation => 'Vacaciones',
        DayKind.holiday => 'Festivo',
        DayKind.sick => 'Baja',
      };

  String get emoji => switch (this) {
        DayKind.work => '🕘',
        DayKind.vacation => '🏖️',
        DayKind.holiday => '🎉',
        DayKind.sick => '🩺',
      };

  static DayKind parse(String? value) => DayKind.values.firstWhere(
        (kind) => kind.name == value,
        orElse: () => DayKind.work,
      );
}

String dateKey(DateTime date) =>
    '${date.year.toString().padLeft(4, '0')}-'
    '${date.month.toString().padLeft(2, '0')}-'
    '${date.day.toString().padLeft(2, '0')}';

DateTime mondayOf(DateTime date) =>
    DateTime(date.year, date.month, date.day - (date.weekday - 1));

DateTime startOfWeek(DateTime date, int weekStart) =>
    DateTime(date.year, date.month, date.day - ((date.weekday - weekStart + 7) % 7));

String formatMinutes(int minutes) {
  final hours = minutes ~/ 60;
  final remainder = minutes.remainder(60);
  return '${hours}h ${remainder.toString().padLeft(2, '0')}';
}

String formatClock(int minute) =>
    '${(minute ~/ 60).toString().padLeft(2, '0')}:'
    '${(minute % 60).toString().padLeft(2, '0')}';

int sumWorked(Iterable<WorkMovement> movements) =>
    movements.fold(0, (sum, movement) => sum + movement.workedMinutes);

int dailyTarget(DateTime date, List<int> targets) => targets[date.weekday - 1];

int weeklyTarget(DateTime start, List<int> targets) {
  var total = 0;
  for (var day = 0; day < 7; day++) {
    total += dailyTarget(start.add(Duration(days: day)), targets);
  }
  return total;
}
