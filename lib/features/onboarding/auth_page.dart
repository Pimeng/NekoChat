import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import '../../app/app_controller.dart';

// 品牌靛蓝（取自种子色）与「橘猫」暖橙点睛色。
const _brandIndigo = Color(0xFF4666E5);
const _brandIndigoDeep = Color(0xFF2B338A);
const _catOrange = Color(0xFFF7A94A);

class AuthPage extends StatefulWidget {
  const AuthPage({
    super.key,
    required this.controller,
    this.windowControls = true,
  });
  final AppController controller;

  /// 真实构建里为无边框窗口：铺满窗口并自绘最小化/关闭、支持拖动；
  /// 组件预览传 false，退化为居中圆角卡片、无窗口按钮。
  final bool windowControls;

  @override
  State<AuthPage> createState() => _AuthPageState();
}

class _AuthPageState extends State<AuthPage> {
  final _name = TextEditingController();
  final _password = TextEditingController();
  final _confirmation = TextEditingController();
  bool _busy = false;
  bool _obscure = true;

  @override
  void dispose() {
    _name.dispose();
    _password.dispose();
    _confirmation.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy) return;
    final setup = widget.controller.stage == AppStage.setup;
    if (setup && _password.text != _confirmation.text) {
      _show('两次输入的密码不一致');
      return;
    }
    setState(() => _busy = true);
    widget.controller.clearError();
    if (setup) {
      await widget.controller.setup(
        displayName: _name.text,
        password: _password.text,
      );
    } else {
      await widget.controller.unlock(_password.text);
    }
    if (mounted) setState(() => _busy = false);
  }

  void _show(String message) => ScaffoldMessenger.of(
    context,
  ).showSnackBar(SnackBar(content: Text(message)));

  @override
  Widget build(BuildContext context) {
    final setup = widget.controller.stage == AppStage.setup;
    final error = widget.controller.errorMessage;
    final form = _AuthForm(
      setup: setup,
      busy: _busy,
      obscure: _obscure,
      error: error,
      name: _name,
      password: _password,
      confirmation: _confirmation,
      onToggleObscure: () => setState(() => _obscure = !_obscure),
      onSubmit: _submit,
    );
    return widget.windowControls
        ? _buildWindowed(context, form)
        : _buildEmbedded(context, form);
  }

  /// 真实构建：无边框窗口，两栏铺满窗口，顶部可拖动，右上角最小化/关闭。
  Widget _buildWindowed(BuildContext context, Widget form) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: scheme.surface,
      body: Stack(
        children: [
          Positioned.fill(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SizedBox(
                  width: 320,
                  child: DragToMoveArea(child: _AuthHero()),
                ),
                Expanded(child: _centeredForm(form)),
              ],
            ),
          ),
          // 表单一侧顶部留一条可拖动区（位于按钮之下）。
          const Positioned(
            top: 0,
            left: 320,
            right: 0,
            height: 46,
            child: DragToMoveArea(child: SizedBox.expand()),
          ),
          Positioned(
            top: 8,
            right: 10,
            child: Row(
              children: [
                _WindowButton(
                  icon: Icons.remove,
                  tooltip: '最小化',
                  onTap: () => windowManager.minimize(),
                ),
                const SizedBox(width: 4),
                _WindowButton(
                  icon: Icons.close_rounded,
                  tooltip: '关闭',
                  danger: true,
                  onTap: () => windowManager.close(),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 组件预览：居中圆角卡片（带入场动画），不控制窗口。
  Widget _buildEmbedded(BuildContext context, Widget form) {
    final reduceMotion = MediaQuery.of(context).disableAnimations;
    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(28),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 840),
            child: TweenAnimationBuilder<double>(
              duration: reduceMotion
                  ? Duration.zero
                  : const Duration(milliseconds: 460),
              curve: const Cubic(0.16, 1.0, 0.3, 1.0),
              tween: Tween(begin: 0, end: 1),
              builder: (context, t, child) => Opacity(
                opacity: t.clamp(0.0, 1.0),
                child: Transform.translate(
                  offset: Offset(0, (1 - t) * 18),
                  child: child,
                ),
              ),
              child: Material(
                elevation: 18,
                shadowColor: _brandIndigo.withValues(alpha: 0.22),
                borderRadius: BorderRadius.circular(24),
                clipBehavior: Clip.antiAlias,
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    // 窄屏（组件预览小视口）只留表单。
                    if (constraints.maxWidth < 680) return form;
                    // 固定高度，避免创建/解锁两种状态高度跳动。
                    return SizedBox(
                      height: 512,
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          const SizedBox(width: 320, child: _AuthHero()),
                          Expanded(child: _centeredForm(form)),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 表单在可用高度内垂直居中，内容超高时滚动。
  Widget _centeredForm(Widget form) => LayoutBuilder(
    builder: (context, constraints) => SingleChildScrollView(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          minHeight: constraints.maxHeight.isFinite ? constraints.maxHeight : 0,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [form],
        ),
      ),
    ),
  );
}

/// 无边框窗口右上角的最小化/关闭按钮。
class _WindowButton extends StatefulWidget {
  const _WindowButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.danger = false,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final bool danger;

  @override
  State<_WindowButton> createState() => _WindowButtonState();
}

class _WindowButtonState extends State<_WindowButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final hoverColor = widget.danger
        ? scheme.error
        : scheme.onSurface.withValues(alpha: 0.1);
    final iconColor = _hover && widget.danger
        ? Colors.white
        : scheme.onSurfaceVariant;
    return Tooltip(
      message: widget.tooltip,
      child: MouseRegion(
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            width: 34,
            height: 28,
            decoration: BoxDecoration(
              color: _hover ? hoverColor : Colors.transparent,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(widget.icon, size: 17, color: iconColor),
          ),
        ),
      ),
    );
  }
}

/// 左侧品牌墙：靛蓝渐变 + 柔光色块 + 橘猫暖橙徽标 + 局域网卖点。
class _AuthHero extends StatelessWidget {
  const _AuthHero();

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [_brandIndigo, _brandIndigoDeep],
        ),
      ),
      child: Stack(
        children: [
          // 暖橙柔光，呼应「橘猫」。
          Positioned(
            top: -70,
            right: -60,
            child: _Glow(
              size: 220,
              color: _catOrange.withValues(alpha: 0.55),
            ),
          ),
          Positioned(
            bottom: -80,
            left: -70,
            child: _Glow(
              size: 240,
              color: const Color(0xFF7E8CF0).withValues(alpha: 0.45),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(28, 32, 24, 30),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 56,
                  height: 56,
                  padding: const EdgeInsets.all(9),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(16),
                    boxShadow: [
                      BoxShadow(
                        color: _brandIndigoDeep.withValues(alpha: 0.35),
                        blurRadius: 16,
                        offset: const Offset(0, 6),
                      ),
                    ],
                  ),
                  child: Image.asset('assets/app.png', fit: BoxFit.contain),
                ),
                const SizedBox(height: 20),
                const Text(
                  'NekoChat',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 27,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.5,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Glow extends StatelessWidget {
  const _Glow({required this.size, required this.color});
  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(
      shape: BoxShape.circle,
      gradient: RadialGradient(colors: [color, color.withValues(alpha: 0)]),
    ),
  );
}

/// 右侧表单：创建身份或解锁。
class _AuthForm extends StatelessWidget {
  const _AuthForm({
    required this.setup,
    required this.busy,
    required this.obscure,
    required this.error,
    required this.name,
    required this.password,
    required this.confirmation,
    required this.onToggleObscure,
    required this.onSubmit,
  });

  final bool setup;
  final bool busy;
  final bool obscure;
  final String? error;
  final TextEditingController name;
  final TextEditingController password;
  final TextEditingController confirmation;
  final VoidCallback onToggleObscure;
  final Future<void> Function() onSubmit;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(36, 40, 36, 36),
      child: AutofillGroup(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              setup ? '创建本机身份' : '解锁 NekoChat',
              style: theme.textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              setup ? '无需服务器，身份只保存在这台电脑上' : '输入本地密码以恢复身份和聊天记录',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 26),
            if (setup) ...[
              TextField(
                controller: name,
                autofocus: true,
                maxLength: 32,
                autofillHints: const [AutofillHints.nickname],
                textInputAction: TextInputAction.next,
                decoration: _fieldDecoration(
                  context,
                  label: '昵称',
                  icon: Icons.person_outline_rounded,
                ),
              ),
              const SizedBox(height: 14),
            ],
            TextField(
              controller: password,
              obscureText: obscure,
              autofillHints: const [AutofillHints.password],
              textInputAction: setup
                  ? TextInputAction.next
                  : TextInputAction.done,
              onSubmitted: setup ? null : (_) => onSubmit(),
              decoration: _fieldDecoration(
                context,
                label: '本地解锁密码',
                icon: Icons.lock_outline_rounded,
                suffix: IconButton(
                  onPressed: onToggleObscure,
                  icon: Icon(
                    obscure
                        ? Icons.visibility_rounded
                        : Icons.visibility_off_rounded,
                  ),
                ),
              ),
            ),
            if (setup) ...[
              const SizedBox(height: 14),
              TextField(
                controller: confirmation,
                obscureText: obscure,
                textInputAction: TextInputAction.done,
                onSubmitted: (_) => onSubmit(),
                decoration: _fieldDecoration(
                  context,
                  label: '再次输入密码',
                  icon: Icons.lock_reset_rounded,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                '密码仅用于解锁本机数据，忘记后无法恢复。至少 4 个字符。',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  height: 1.4,
                ),
              ),
            ],
            if (error != null) ...[
              const SizedBox(height: 16),
              _ErrorBanner(message: error!),
            ],
            const SizedBox(height: 26),
            SizedBox(
              height: 50,
              child: FilledButton.icon(
                onPressed: busy ? null : onSubmit,
                style: FilledButton.styleFrom(
                  backgroundColor: _brandIndigo,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                  textStyle: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                icon: busy
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : Icon(
                        setup
                            ? Icons.arrow_forward_rounded
                            : Icons.lock_open_rounded,
                      ),
                label: Text(setup ? '创建并进入' : '解锁'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  InputDecoration _fieldDecoration(
    BuildContext context, {
    required String label,
    required IconData icon,
    Widget? suffix,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return InputDecoration(
      labelText: label,
      prefixIcon: Icon(icon),
      suffixIcon: suffix,
      filled: true,
      fillColor: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide.none,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: const BorderSide(color: _brandIndigo, width: 1.6),
      ),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message});
  final String message;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: scheme.errorContainer.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(Icons.error_outline_rounded, color: scheme.error, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: TextStyle(color: scheme.error, height: 1.35),
            ),
          ),
        ],
      ),
    );
  }
}
