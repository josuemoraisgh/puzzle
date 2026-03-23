import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../core/config/app_config.dart';
import '../../../core/router/app_router.dart';
import '../../../core/theme/app_theme.dart';

/// Tela de QR Code para o professor exibir aos alunos.
/// A imagem do QR code deve estar em assets/qrcode.png.
/// O endereço exibido vem de assets/config.json (campo student_url).
class QrCodePage extends StatelessWidget {
  const QrCodePage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(gradient: AppTheme.bgGradient),
        child: SafeArea(
          child: Column(
            children: [
              // ── AppBar ────────────────────────────────────────────────
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
                child: Row(
                  children: [
                    IconButton(
                      icon: const Icon(Icons.arrow_back_ios_new_rounded,
                          color: AppTheme.textSecondary),
                      tooltip: 'Voltar',
                      onPressed: () => context.go(AppRouter.professor),
                    ),
                    const Expanded(
                      child: Text(
                        'QR Code do Aluno',
                        style: TextStyle(
                          color: AppTheme.textPrimary,
                          fontWeight: FontWeight.w800,
                          fontSize: 18,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ),
                    const SizedBox(width: 48), // balanceia o botão de voltar
                  ],
                ),
              ),

              // ── Conteúdo centralizado ─────────────────────────────────
              const Expanded(
                child: Center(
                  child: _QrCodeContent(),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _QrCodeContent extends StatelessWidget {
  const _QrCodeContent();

  @override
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.of(context).size.width;
    final qrSize = (screenWidth * 0.5).clamp(200.0, 480.0);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // ── Imagem do QR Code ─────────────────────────────────────────
        Container(
          width: qrSize,
          height: qrSize,
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(24),
            boxShadow: [
              BoxShadow(
                color: AppTheme.primary.withValues(alpha: 0.4),
                blurRadius: 32,
                spreadRadius: 4,
              ),
            ],
          ),
          child: Image.asset(
            'assets/qrcode.png',
            fit: BoxFit.contain,
            errorBuilder: (_, __, ___) => const _QrCodePlaceholder(),
          ),
        ),

        const SizedBox(height: 32),

        // ── URL do aluno ──────────────────────────────────────────────
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Text(
            AppConfig.studentUrl,
            style: const TextStyle(
              color: AppTheme.textPrimary,
              fontSize: 18,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.5,
            ),
            textAlign: TextAlign.center,
          ),
        ),
      ],
    );
  }
}

/// Exibido enquanto assets/qrcode.png não existir.
class _QrCodePlaceholder extends StatelessWidget {
  const _QrCodePlaceholder();

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: const [
        Icon(Icons.qr_code_2_rounded, size: 80, color: AppTheme.textSecondary),
        SizedBox(height: 12),
        Text(
          'Adicione assets/qrcode.png',
          style: TextStyle(color: AppTheme.textSecondary, fontSize: 13),
          textAlign: TextAlign.center,
        ),
      ],
    );
  }
}
