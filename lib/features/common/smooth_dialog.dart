import 'package:material_ui/material_ui.dart';

/// 统一的居中对话框弹出辅助函数：
/// 替代默认生硬的线性淡入淡出，提供柔和的微缩放 + 轻上浮淡入，以及即刻响应的平滑退场。
Future<T?> showNekoDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool barrierDismissible = true,
  bool useRootNavigator = true,
  Color? barrierColor,
}) {
  final effectiveBarrierColor =
      barrierColor ??
      (Theme.of(context).brightness == Brightness.dark
          ? Colors.black54
          : Colors.black38);
  final themes = InheritedTheme.capture(
    from: context,
    to: Navigator.of(context, rootNavigator: useRootNavigator).context,
  );
  return Navigator.of(context, rootNavigator: useRootNavigator).push<T>(
    _SmoothDialogRoute<T>(
      builder: builder,
      themes: themes,
      barrierDismissible: barrierDismissible,
      barrierColor: effectiveBarrierColor,
      barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
    ),
  );
}

class _SmoothDialogRoute<T> extends PopupRoute<T> {
  _SmoothDialogRoute({
    required this.builder,
    required this.themes,
    required this.barrierDismissible,
    required this.barrierColor,
    required this.barrierLabel,
  });

  final WidgetBuilder builder;
  final CapturedThemes themes;

  @override
  final bool barrierDismissible;

  @override
  final Color barrierColor;

  @override
  final String barrierLabel;

  @override
  Duration get transitionDuration => const Duration(milliseconds: 240);

  @override
  Duration get reverseTransitionDuration => const Duration(milliseconds: 170);

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) {
    return SafeArea(
      child: Builder(
        builder: (context) => themes.wrap(builder(context)),
      ),
    );
  }

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final curved = CurvedAnimation(
      parent: animation,
      curve: const Cubic(0.16, 1.0, 0.3, 1.0),
      reverseCurve: Curves.easeOutCubic,
    );
    final fade = CurvedAnimation(
      parent: animation,
      curve: const Interval(0.0, 0.7, curve: Curves.easeOut),
      reverseCurve: Curves.easeOut,
    );
    return FadeTransition(
      opacity: fade,
      child: SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(0, 0.03),
          end: Offset.zero,
        ).animate(curved),
        child: ScaleTransition(
          scale: Tween<double>(begin: 0.94, end: 1.0).animate(curved),
          child: child,
        ),
      ),
    );
  }
}
