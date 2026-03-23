import 'dart:js_interop';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:web/web.dart' as web;

import '../theme/app_theme.dart';
import 'responsive.dart';

/// Botão fullscreen — visível apenas no desktop web.
/// Usa a Fullscreen API do browser (equivalente ao F11).
class FullscreenButton extends StatefulWidget {
  const FullscreenButton({super.key});

  @override
  State<FullscreenButton> createState() => _FullscreenButtonState();
}

class _FullscreenButtonState extends State<FullscreenButton> {
  bool _isFullscreen = false;

  @override
  void initState() {
    super.initState();
    web.document.addEventListener(
      'fullscreenchange',
      (web.Event _) {
        if (mounted) {
          setState(() {
            _isFullscreen = web.document.fullscreenElement != null;
          });
        }
      }.toJS,
    );
  }

  void _toggle() {
    if (_isFullscreen) {
      web.document.exitFullscreen();
    } else {
      web.document.documentElement?.requestFullscreen();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!kIsWeb || !Responsive.isDesktop(context)) return const SizedBox.shrink();

    return IconButton(
      icon: Icon(
        _isFullscreen ? Icons.fullscreen_exit : Icons.fullscreen,
        color: AppTheme.textSecondary,
      ),
      tooltip: _isFullscreen ? 'Sair do fullscreen' : 'Fullscreen',
      onPressed: _toggle,
    );
  }
}
