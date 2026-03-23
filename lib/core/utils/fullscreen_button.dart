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
  JSFunction? _listener;

  @override
  void initState() {
    super.initState();
    // Lê o estado real do browser ao montar (pode estar fullscreen ao voltar para a página)
    _isFullscreen = web.document.fullscreenElement != null;

    _listener = (web.Event _) {
      if (mounted) {
        setState(() => _isFullscreen = web.document.fullscreenElement != null);
      }
    }.toJS;
    web.document.addEventListener('fullscreenchange', _listener!);
  }

  @override
  void dispose() {
    if (_listener != null) {
      web.document.removeEventListener('fullscreenchange', _listener!);
    }
    super.dispose();
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
