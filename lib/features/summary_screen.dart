import 'package:material_ui/material_ui.dart';

import '../data/app_database.dart';
import '../domain/work_time.dart';

enum _SummaryRange { week, month, year }

class SummaryScreen extends StatefulWidget {
  const SummaryScreen({super.key});

  @override
  State<SummaryScreen> createState() => _SummaryScreenState();
}

class _SummaryScreenState extends State<SummaryScreen> {
  final _database = AppDatabase.instance;
  _SummaryRange _range = _SummaryRange.week;
  DateTime _anchor = DateTime.now();
  bool _loading = true;
  List<WorkMovement> _movements = [];
  List<Map<String, Object?>> _accounts = [];
  List<int> _targets = [480, 480, 480, 480, 480, 0, 0];
  Map<String, DayKind> _kinds = {};
  Map<String, int> _overrides = {};
  int _weekStartDay = 1;

  DateTime get _from {
    switch (_range) {
      case _SummaryRange.week:
        return startOfWeek(_anchor, _weekStartDay);
      case _SummaryRange.month:
        return DateTime(_anchor.year, _anchor.month);
      case _SummaryRange.year:
        return DateTime(_anchor.year);
    }
  }

  DateTime get _to {
    switch (_range) {
      case _SummaryRange.week:
        return _from.add(const Duration(days: 6));
      case _SummaryRange.month:
        return DateTime(_anchor.year, _anchor.month + 1, 0);
      case _SummaryRange.year:
        return DateTime(_anchor.year, 12, 31);
    }
  }

  int get _worked => sumWorked(_movements);
  int get _registeredDays =>
      _movements.map((movement) => movement.date).toSet().length;

  List<Map<String, Object?>> get _accountTotals =>
      _accounts
          .map(
            (account) => {
              'account': account,
              'minutes': _accountTotal(account['id'] as int),
            },
          )
          .where((item) => item['minutes'] != 0)
          .toList()
        ..sort((a, b) => (b['minutes'] as int).compareTo(a['minutes'] as int));

  int get _maxAccountMinutes => _accountTotals.fold<int>(
    1,
    (max, item) =>
        (item['minutes'] as int) > max ? item['minutes'] as int : max,
  );

  int _targetFor(DateTime date) {
    if ((_kinds[dateKey(date)] ?? DayKind.work) != DayKind.work) return 0;
    return _overrides[dateKey(date)] ?? dailyTarget(date, _targets);
  }

  int get _target {
    var sum = 0;
    for (
      var date = _from;
      !date.isAfter(_to);
      date = date.add(const Duration(days: 1))
    ) {
      sum += _targetFor(date);
    }
    return sum;
  }

  int get _extra {
    if (_range != _SummaryRange.year) {
      return (_worked - _target).clamp(0, 1 << 30);
    }
    var extra = 0;
    var weekStart = startOfWeek(_from, _weekStartDay);
    while (!weekStart.isAfter(_to)) {
      final weekEnd = weekStart.add(const Duration(days: 6));
      final from = weekStart.isBefore(_from) ? _from : weekStart;
      final to = weekEnd.isAfter(_to) ? _to : weekEnd;
      final weekMovements = _movements.where((movement) {
        final date = DateTime.parse(movement.date);
        return !date.isBefore(from) && !date.isAfter(to);
      });
      var weekTarget = 0;
      for (
        var date = from;
        !date.isAfter(to);
        date = date.add(const Duration(days: 1))
      ) {
        weekTarget += _targetFor(date);
      }
      extra += (sumWorked(weekMovements) - weekTarget).clamp(0, 1 << 30);
      weekStart = weekStart.add(const Duration(days: 7));
    }
    return extra;
  }

  @override
  void initState() {
    super.initState();
    _database.revision.addListener(_onDatabaseChanged);
    _load();
  }

  @override
  void dispose() {
    _database.revision.removeListener(_onDatabaseChanged);
    super.dispose();
  }

  void _onDatabaseChanged() {
    if (mounted) _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      _weekStartDay = await _database.weekStart();
      final results = await Future.wait<Object>([
        _database.movementsBetween(_from, _to),
        _database.dayKindsBetween(_from, _to),
        _database.dailyTargets(),
        _database.allAccounts(),
        _database.dateOverrides(),
      ]);
      if (!mounted) return;
      setState(() {
        _movements = results[0] as List<WorkMovement>;
        _kinds = results[1] as Map<String, DayKind>;
        _targets = results[2] as List<int>;
        _accounts = results[3] as List<Map<String, Object?>>;
        _overrides = results[4] as Map<String, int>;
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _movePeriod(int direction) {
    setState(() {
      switch (_range) {
        case _SummaryRange.week:
          _anchor = _anchor.add(Duration(days: direction * 7));
        case _SummaryRange.month:
          _anchor = DateTime(_anchor.year, _anchor.month + direction, 1);
        case _SummaryRange.year:
          _anchor = DateTime(_anchor.year + direction, 1);
      }
    });
    _load();
  }

  int _accountTotal(int id) =>
      sumWorked(_movements.where((movement) => movement.accountId == id));

  int _dayWorked(DateTime date) =>
      sumWorked(_movements.where((movement) => movement.date == dateKey(date)));

  Map<DayKind, int> _excusedBetween(DateTime from, DateTime to) {
    final totals = {for (final kind in DayKind.values) kind: 0};
    for (
      var date = from;
      !date.isAfter(to);
      date = date.add(const Duration(days: 1))
    ) {
      final kind = _kinds[dateKey(date)] ?? DayKind.work;
      if (kind != DayKind.work) {
        totals[kind] =
            totals[kind]! +
            (_overrides[dateKey(date)] ?? dailyTarget(date, _targets));
      }
    }
    return totals;
  }

  List<
    ({
      DateTime from,
      DateTime to,
      int worked,
      int target,
      int extra,
      Map<DayKind, int> excused,
    })
  >
  get _weeksInPeriod {
    final result =
        <
          ({
            DateTime from,
            DateTime to,
            int worked,
            int target,
            int extra,
            Map<DayKind, int> excused,
          })
        >[];
    var week = startOfWeek(_from, _weekStartDay);
    while (!week.isAfter(_to)) {
      final from = week.isBefore(_from) ? _from : week;
      final weekEnd = week.add(const Duration(days: 6));
      final to = weekEnd.isAfter(_to) ? _to : weekEnd;
      final worked = sumWorked(
        _movements.where((movement) {
          final date = DateTime.parse(movement.date);
          return !date.isBefore(from) && !date.isAfter(to);
        }),
      );
      var target = 0;
      for (
        var date = from;
        !date.isAfter(to);
        date = date.add(const Duration(days: 1))
      ) {
        target += _targetFor(date);
      }
      result.add((
        from: from,
        to: to,
        worked: worked,
        target: target,
        extra: (worked - target).clamp(0, 1 << 30),
        excused: _excusedBetween(from, to),
      ));
      week = week.add(const Duration(days: 7));
    }
    return result;
  }

  List<({DateTime date, int worked, int target, Map<DayKind, int> excused})>
  get _monthsInYear {
    return List.generate(12, (index) {
      final from = DateTime(_anchor.year, index + 1);
      final to = DateTime(_anchor.year, index + 2, 0);
      final worked = sumWorked(
        _movements.where((movement) {
          final date = DateTime.parse(movement.date);
          return !date.isBefore(from) && !date.isAfter(to);
        }),
      );
      var target = 0;
      for (
        var date = from;
        !date.isAfter(to);
        date = date.add(const Duration(days: 1))
      ) {
        target += _targetFor(date);
      }
      return (
        date: from,
        worked: worked,
        target: target,
        excused: _excusedBetween(from, to),
      );
    });
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Resumen', style: TextStyle(fontWeight: FontWeight.w800)),
          Text(
            'Horas, objetivos y extras',
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w400),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () {
            setState(() => _anchor = DateTime.now());
            _load();
          },
          child: const Text('Hoy'),
        ),
      ],
    ),
    body: _loading
        ? const Center(child: CircularProgressIndicator())
        : RefreshIndicator(
            onRefresh: _load,
            child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 5, 20, 32),
              children: [
                _rangeSelector(),
                const SizedBox(height: 16),
                _periodSelector(),
                const SizedBox(height: 16),
                _totalCard(),
                const SizedBox(height: 12),
                _periodStats(),
                const SizedBox(height: 20),
                if (_range == _SummaryRange.week) ...[
                  _weeklyBreakdown(),
                  const SizedBox(height: 20),
                ],
                _accountBreakdown(),
                const SizedBox(height: 16),
                if (_range == _SummaryRange.month) _monthlyBreakdown(),
                if (_range == _SummaryRange.year) _yearlyBreakdown(),
                if (_range != _SummaryRange.week) ...[
                  const SizedBox(height: 12),
                  _infoBanner(
                    _range == _SummaryRange.month
                        ? 'El extra global compara las horas trabajadas con el objetivo del mes. El extra semanal se muestra en cada semana.'
                        : 'Las horas extra se calculan por semanas; solo se cuentan los días incluidos en este año.',
                  ),
                ],
              ],
            ),
          ),
  );

  Widget _rangeSelector() => Container(
    padding: const EdgeInsets.all(4),
    decoration: BoxDecoration(
      color: const Color(0xffe9edf5),
      borderRadius: BorderRadius.circular(15),
    ),
    child: Row(
      children: [
        _rangeOption(_SummaryRange.week, 'Semana'),
        _rangeOption(_SummaryRange.month, 'Mes'),
        _rangeOption(_SummaryRange.year, 'Año'),
      ],
    ),
  );

  Widget _rangeOption(_SummaryRange range, String label) {
    final selected = _range == range;
    return Expanded(
      child: GestureDetector(
        onTap: () {
          setState(() => _range = range);
          _load();
        },
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            color: selected ? Colors.white : Colors.transparent,
            borderRadius: BorderRadius.circular(12),
            boxShadow: selected
                ? const [BoxShadow(color: Color(0x10000000), blurRadius: 6)]
                : null,
          ),
          child: Text(
            label,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
              fontSize: 12,
              color: selected
                  ? const Color(0xff263047)
                  : const Color(0xff7a8496),
            ),
          ),
        ),
      ),
    );
  }

  Widget _periodSelector() => Card(
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 6),
      child: Row(
        children: [
          IconButton(
            onPressed: () => _movePeriod(-1),
            icon: const Icon(Icons.chevron_left_rounded),
          ),
          Expanded(
            child: Column(
              children: [
                Text(
                  _periodLabel(),
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 15,
                  ),
                ),
                Text(
                  _range == _SummaryRange.week
                      ? 'Semana completa'
                      : _range == _SummaryRange.month
                      ? 'Extra por semanas que empiezan en el mes'
                      : 'Extra por semanas que empiezan en el año',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Color(0xff8993a5),
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            onPressed: () => _movePeriod(1),
            icon: const Icon(Icons.chevron_right_rounded),
          ),
        ],
      ),
    ),
  );

  Widget _totalCard() {
    final progress = _target == 0 ? 0.0 : (_worked / _target).clamp(0.0, 1.0);
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: const Color(0xff1d3154),
        borderRadius: BorderRadius.circular(23),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text(
                  'Horas trabajadas',
                  style: TextStyle(color: Color(0xffcad5e8), fontSize: 12),
                ),
              ),
              if (_extra > 0)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 9,
                    vertical: 5,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0x263fca8a),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    '+${formatMinutes(_extra)} extra',
                    style: const TextStyle(
                      color: Color(0xff9ef0c5),
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 7),
          Text(
            formatMinutes(_worked),
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w800,
              fontSize: 30,
            ),
          ),
          const SizedBox(height: 15),
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: LinearProgressIndicator(
              value: progress,
              minHeight: 7,
              backgroundColor: const Color(0xff435778),
              valueColor: const AlwaysStoppedAnimation<Color>(
                Color(0xff91b0ff),
              ),
            ),
          ),
          const SizedBox(height: 15),
          Row(
            children: [
              _totalLabel('Objetivo', formatMinutes(_target)),
              const Spacer(),
              _totalLabel(
                _worked >= _target ? 'Balance' : 'Faltan',
                '${_worked >= _target ? '+' : ''}${formatMinutes((_worked - _target).abs())}',
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _totalLabel(String label, String value) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        label,
        style: const TextStyle(color: Color(0xffc4cfe1), fontSize: 10),
      ),
      const SizedBox(height: 4),
      Text(
        value,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 14,
          fontWeight: FontWeight.w800,
        ),
      ),
    ],
  );

  Widget _periodStats() => Row(
    children: [
      Expanded(
        child: _statCard(
          'Objetivo',
          formatMinutes(_target),
          _range == _SummaryRange.week ? 'De esta semana' : 'Del periodo',
        ),
      ),
      const SizedBox(width: 8),
      Expanded(
        child: _statCard(
          'Extra',
          _extra > 0 ? formatMinutes(_extra) : '—',
          _range == _SummaryRange.month
              ? 'Balance del mes'
              : 'Calculado por semana',
        ),
      ),
      const SizedBox(width: 8),
      Expanded(child: _statCard('Días', '$_registeredDays', 'Con horas')),
    ],
  );

  Widget _statCard(String label, String value, String note) => Card(
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
    child: Padding(
      padding: const EdgeInsets.all(11),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: const TextStyle(color: Color(0xff8993a5), fontSize: 10),
          ),
          const SizedBox(height: 5),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              value,
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800),
            ),
          ),
          const SizedBox(height: 3),
          Text(
            note,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Color(0xff8993a5), fontSize: 9),
          ),
        ],
      ),
    ),
  );

  Widget _weeklyBreakdown() {
    final maxScheduled = List.generate(7, (index) {
      final date = _from.add(Duration(days: index));
      final kind = _kinds[dateKey(date)] ?? DayKind.work;
      return kind == DayKind.work
          ? _targetFor(date)
          : (_overrides[dateKey(date)] ?? dailyTarget(date, _targets));
    }).fold<int>(1, (value, day) => day > value ? day : value);
    final maxExtraRatio = List.generate(7, (index) {
      final date = _from.add(Duration(days: index));
      final target = _targetFor(date);
      final worked = _dayWorked(date);
      return (worked - target).clamp(0, 1 << 30) /
          (target == 0 ? maxScheduled : target);
    }).fold<double>(0, (value, ratio) => ratio > value ? ratio : value);
    final trackWidth = 100 / (1 + maxExtraRatio);
    return _breakdownCard(
      title: 'Días de la semana',
      subtitle: '${_weekday(_from.weekday)} a ${_weekday(_to.weekday)}',
      legend: [
        _legend('Hasta objetivo', const Color(0xff3978f6)),
        _legend('Exceso diario', const Color(0xffffa726)),
        _legend('Vacaciones', const Color(0xff8c6bd9)),
        _legend('Baja', const Color(0xffed7891)),
        _legend('Festivo', const Color(0xff3eaf9b)),
      ],
      rows: [
        for (var index = 0; index < 7; index++)
          _dayBreakdownRow(
            _from.add(Duration(days: index)),
            trackWidth,
            maxScheduled,
          ),
      ],
    );
  }

  Widget _dayBreakdownRow(DateTime date, double trackWidth, int maxScheduled) {
    final worked = _dayWorked(date);
    final target = _targetFor(date);
    final kind = _kinds[dateKey(date)] ?? DayKind.work;
    final scheduled = kind == DayKind.work
        ? target
        : (_overrides[dateKey(date)] ?? dailyTarget(date, _targets));
    final denominator = target + (kind == DayKind.work ? 0 : scheduled);
    final denominatorSafe = denominator == 0 ? maxScheduled : denominator;
    final workedTargetWidth =
        (worked.clamp(0, target) / denominatorSafe) * trackWidth;
    final excessWidth =
        (worked > target
                ? ((worked - target) / denominatorSafe) * trackWidth
                : 0.0)
            .clamp(0.0, 100.0);
    final excusedWidth = kind == DayKind.work
        ? 0.0
        : (scheduled / denominatorSafe) * trackWidth;
    final bar = Container(
      height: 8,
      width: trackWidth,
      decoration: BoxDecoration(
        color: const Color(0xffedf0f5),
        borderRadius: BorderRadius.circular(8),
      ),
      clipBehavior: Clip.antiAlias,
      child: Row(
        children: [
          if (kind == DayKind.work) ...[
            Container(width: workedTargetWidth, color: const Color(0xff3978f6)),
            if (excessWidth > 0)
              Container(width: excessWidth, color: const Color(0xffffa726)),
          ] else
            Container(width: excusedWidth, color: _kindColor(kind)),
        ],
      ),
    );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Row(
        children: [
          SizedBox(
            width: 106,
            child: Text(
              '${_weekday(date.weekday)} ${date.day}/${date.month}',
              style: const TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: Color(0xff536078),
              ),
            ),
          ),
          Expanded(child: bar),
          const SizedBox(width: 8),
          SizedBox(
            width: 54,
            child: Text(
              formatMinutes(worked),
              textAlign: TextAlign.right,
              style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
    );
  }

  Widget _accountBreakdown() {
    final totals = _accountTotals;
    return _breakdownCard(
      title: 'Por cuenta',
      subtitle: 'Horas del periodo seleccionado',
      rows: totals.isEmpty
          ? [
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text(
                  'No hay horas registradas en este periodo.',
                  style: TextStyle(color: Color(0xff8993a5)),
                ),
              ),
            ]
          : [
              for (final item in totals)
                _accountBreakdownRow(
                  item['account'] as Map<String, Object?>,
                  item['minutes'] as int,
                ),
            ],
    );
  }

  Widget _accountBreakdownRow(Map<String, Object?> account, int minutes) {
    final color = Color(account['color'] as int);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      child: Row(
        children: [
          Container(
            width: 9,
            height: 9,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 9),
          SizedBox(
            width: 92,
            child: Text(
              '${account['name']}${account['archived'] == 1 ? ' ·' : ''}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: LinearProgressIndicator(
                value: minutes / _maxAccountMinutes,
                minHeight: 6,
                backgroundColor: const Color(0xffedf0f5),
                valueColor: AlwaysStoppedAnimation<Color>(color),
              ),
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 54,
            child: Text(
              formatMinutes(minutes),
              textAlign: TextAlign.right,
              style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
    );
  }

  Widget _monthlyBreakdown() {
    final weeks = _weeksInPeriod;
    var maxWorked = 1;
    for (final week in weeks) {
      final totalExcused = week.excused.values.fold<int>(
        0,
        (sum, value) => sum + value,
      );
      maxWorked = [
        maxWorked,
        week.target + totalExcused,
        week.worked + totalExcused,
      ].reduce((a, b) => a > b ? a : b);
    }
    return _breakdownCard(
      title: 'Semanas del mes',
      subtitle: 'Días del mes agrupados por semanas',
      legend: [
        _legend('Trabajadas', const Color(0xff3978f6)),
        _legend('Vacaciones', const Color(0xff8c6bd9)),
        _legend('Baja', const Color(0xffed7891)),
        _legend('Festivo', const Color(0xff3eaf9b)),
      ],
      rows: [
        for (final week in weeks)
          _periodBarRow(
            '${week.from.day}/${week.from.month} – ${week.to.day}/${week.to.month}',
            week.worked,
            week.excused,
            maxWorked,
            extra: week.extra,
          ),
      ],
    );
  }

  Widget _yearlyBreakdown() {
    final months = _monthsInYear;
    var maxMonth = 1;
    for (final month in months) {
      final excused = month.excused.values.fold<int>(
        0,
        (sum, value) => sum + value,
      );
      maxMonth = maxMonth > month.worked + excused
          ? maxMonth
          : month.worked + excused;
    }
    return _breakdownCard(
      title: 'Meses del año',
      subtitle: 'Horas trabajadas y justificadas por mes',
      legend: [
        _legend('Trabajadas', const Color(0xff3978f6)),
        _legend('Vacaciones', const Color(0xff8c6bd9)),
        _legend('Baja', const Color(0xffed7891)),
        _legend('Festivo', const Color(0xff3eaf9b)),
      ],
      rows: [
        for (final month in months)
          _periodBarRow(
            _monthName(month.date.month),
            month.worked,
            month.excused,
            maxMonth,
          ),
      ],
    );
  }

  Widget _periodBarRow(
    String label,
    int worked,
    Map<DayKind, int> excused,
    int maxValue, {
    int? extra,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Row(
        children: [
          SizedBox(
            width: 92,
            child: Text(
              label,
              style: const TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: Color(0xff536078),
              ),
            ),
          ),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) => ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: SizedBox(
                  height: 6,
                  child: Row(
                    children: [
                      if (worked > 0)
                        Container(
                          width: worked / maxValue * constraints.maxWidth,
                          color: const Color(0xff3978f6),
                        ),
                      for (final kind in [
                        DayKind.vacation,
                        DayKind.sick,
                        DayKind.holiday,
                      ])
                        if ((excused[kind] ?? 0) > 0)
                          Container(
                            width:
                                (excused[kind] ?? 0) /
                                maxValue *
                                constraints.maxWidth,
                            color: _kindColor(kind),
                          ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          if (extra != null && extra > 0) ...[
            const SizedBox(width: 5),
            Text(
              '+${formatMinutes(extra)}',
              style: const TextStyle(
                color: Color(0xffad6b00),
                fontSize: 9,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
          const SizedBox(width: 7),
          SizedBox(
            width: 53,
            child: Text(
              formatMinutes(worked),
              textAlign: TextAlign.right,
              style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
    );
  }

  Widget _breakdownCard({
    required String title,
    required String subtitle,
    required List<Widget> rows,
    List<Widget> legend = const [],
  }) => Card(
    clipBehavior: Clip.antiAlias,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 14, 14, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                subtitle,
                style: const TextStyle(color: Color(0xff8993a5), fontSize: 10),
              ),
              if (legend.isNotEmpty) ...[
                const SizedBox(height: 8),
                Wrap(spacing: 10, runSpacing: 4, children: legend),
              ],
            ],
          ),
        ),
        for (var index = 0; index < rows.length; index++) ...[
          if (index > 0) const Divider(height: 1, indent: 12, endIndent: 12),
          rows[index],
        ],
      ],
    ),
  );

  Widget _legend(String label, Color color) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Container(
        width: 8,
        height: 8,
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(3),
        ),
      ),
      const SizedBox(width: 4),
      Text(
        label,
        style: const TextStyle(color: Color(0xff8993a5), fontSize: 9),
      ),
    ],
  );

  Color _kindColor(DayKind kind) => switch (kind) {
    DayKind.vacation => const Color(0xff8c6bd9),
    DayKind.sick => const Color(0xffed7891),
    DayKind.holiday => const Color(0xff3eaf9b),
    DayKind.work => const Color(0xff3978f6),
  };

  Widget _infoBanner(String text) => Container(
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: const Color(0xffedf2ff),
      borderRadius: BorderRadius.circular(14),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Icon(
          Icons.info_outline_rounded,
          size: 17,
          color: Color(0xff3978f6),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            text,
            style: const TextStyle(color: Color(0xff536078), fontSize: 11),
          ),
        ),
      ],
    ),
  );

  String _monthName(int month) => const [
    'Enero',
    'Febrero',
    'Marzo',
    'Abril',
    'Mayo',
    'Junio',
    'Julio',
    'Agosto',
    'Septiembre',
    'Octubre',
    'Noviembre',
    'Diciembre',
  ][month - 1];

  String _periodLabel() {
    const months = [
      'enero',
      'febrero',
      'marzo',
      'abril',
      'mayo',
      'junio',
      'julio',
      'agosto',
      'septiembre',
      'octubre',
      'noviembre',
      'diciembre',
    ];
    switch (_range) {
      case _SummaryRange.week:
        final to = _from.add(const Duration(days: 6));
        return '${_from.day} ${months[_from.month - 1]} – '
            '${to.day} ${months[to.month - 1]} ${to.year}';
      case _SummaryRange.month:
        final name = months[_anchor.month - 1];
        return '${name[0].toUpperCase()}${name.substring(1)} ${_anchor.year}';
      case _SummaryRange.year:
        return '${_anchor.year}';
    }
  }
}

String _weekday(int weekday) => const [
  'Lunes',
  'Martes',
  'Miércoles',
  'Jueves',
  'Viernes',
  'Sábado',
  'Domingo',
][weekday - 1];
