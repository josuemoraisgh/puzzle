import 'dart:async';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../core/theme/app_theme.dart';

/// Exibe contagem regressiva baseada em [endsAt].
class TimerWidget extends StatefulWidget {
  final DateTime endsAt;
  final VoidCallback? onTimeUp;
  const TimerWidget({super.key, required this.endsAt, this.onTimeUp});

  @override
  State<TimerWidget> createState() => _TimerWidgetState();
}

class _TimerWidgetState extends State<TimerWidget> {
  late Timer _timer;
  int _seconds = 0;
  int _total = 0;
  bool _timeUpCalled = false;

  @override
  void initState() {
    super.initState();
    _update();
    _total = _seconds;
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(_update);
    });
  }

  void _update() {
    final diff = widget.endsAt.difference(DateTime.now()).inSeconds;
    _seconds = diff < 0 ? 0 : diff;
    if (_seconds == 0 && !_timeUpCalled && widget.onTimeUp != null) {
      _timeUpCalled = true;
      // Chamar no próximo frame para evitar setState durante build
      WidgetsBinding.instance.addPostFrameCallback((_) {
        widget.onTimeUp?.call();
      });
    }
  }

  @override
  void dispose() {
    _timer.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final pct = _total > 0 ? _seconds / _total : 0.0;
    final Color timerColor = _seconds > 10
        ? AppTheme.success
        : _seconds > 5
            ? AppTheme.warning
            : AppTheme.danger;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: AppTheme.cardDecoration(),
      child: Row(
        children: [
          // ── Ícone ────────────────────────────────────────────────────
          Icon(Icons.timer_rounded, color: timerColor, size: 22),
          const SizedBox(width: 10),
          // ── Número ───────────────────────────────────────────────────
          Text(
            '$_seconds',
            style: GoogleFonts.poppins(
              fontSize: 24,
              fontWeight: FontWeight.w900,
              color: timerColor,
            ),
          ),
          const SizedBox(width: 4),
          const Text('s',
              style: TextStyle(color: AppTheme.textSecondary, fontSize: 14)),
          const SizedBox(width: 12),
          // ── Barra de progresso ────────────────────────────────────────
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: pct.clamp(0.0, 1.0),
                backgroundColor: AppTheme.bgCardAlt,
                valueColor: AlwaysStoppedAnimation<Color>(timerColor),
                minHeight: 8,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
