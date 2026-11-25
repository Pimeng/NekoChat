import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';

class MessageComposer extends StatefulWidget {
  const MessageComposer({
    super.key,
    required this.controller,
    required this.enabled,
    required this.onSend,
    this.hasAttachments = false,
    this.sendOnCtrlEnter = false,
    this.onSendOnCtrlEnterChanged,
    this.focusNode,
    this.onPasteAttachments,
    this.onSuggestionPrevious,
    this.onSuggestionNext,
    this.onSuggestionAccept,
    this.onSuggestionDismiss,
  });

  final TextEditingController controller;
  final bool enabled;
  final VoidCallback onSend;

  /// 是否有待发送附件，用于在输入框为空但有附件时高亮发送按钮。
  final bool hasAttachments;

  /// 为 true 时按 Ctrl + Enter 发送、Enter 换行；为 false 时按 Enter 发送、Ctrl + Enter 换行。
  final bool sendOnCtrlEnter;
  final ValueChanged<bool>? onSendOnCtrlEnterChanged;

  /// 由外部持有，方便引用回复后立刻把光标送回输入框。
  final FocusNode? focusNode;
  final Future<bool> Function()? onPasteAttachments;
  final VoidCallback? onSuggestionPrevious;
  final VoidCallback? onSuggestionNext;
  final VoidCallback? onSuggestionAccept;
  final VoidCallback? onSuggestionDismiss;

  @override
  State<MessageComposer> createState() => _MessageComposerState();
}

class _MessageComposerState extends State<MessageComposer>
    with SingleTickerProviderStateMixin {
  late final AnimationController _sendPulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 180),
  );
  late final Animation<double> _sendScale = TweenSequence<double>([
    TweenSequenceItem(
      tween: Tween(begin: 1.0, end: 0.86).chain(CurveTween(curve: Curves.easeOut)),
      weight: 40,
    ),
    TweenSequenceItem(
      tween: Tween(
        begin: 0.86,
        end: 1.0,
      ).chain(CurveTween(curve: Curves.easeOutBack)),
      weight: 60,
    ),
  ]).animate(_sendPulse);

  late bool _sendOnCtrlEnter = widget.sendOnCtrlEnter;

  @override
  void didUpdateWidget(covariant MessageComposer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.sendOnCtrlEnter != widget.sendOnCtrlEnter) {
      _sendOnCtrlEnter = widget.sendOnCtrlEnter;
    }
  }

  @override
  void dispose() {
    _sendPulse.dispose();
    super.dispose();
  }

  void _setSendOnCtrlEnter(bool value) {
    if (_sendOnCtrlEnter == value) return;
    setState(() => _sendOnCtrlEnter = value);
    widget.onSendOnCtrlEnterChanged?.call(value);
  }

  void _triggerSend() {
    if (!widget.enabled) return;
    _sendPulse.forward(from: 0);
    widget.onSend();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final enterAction =
        widget.onSuggestionAccept ??
        (_sendOnCtrlEnter ? _insertNewline : _send);
    final ctrlEnterAction = _sendOnCtrlEnter ? _send : _insertNewline;
    final shortcutHint = _sendOnCtrlEnter
        ? 'Ctrl + Enter 发送，Enter 换行'
        : 'Enter 发送，Ctrl + Enter 换行';
    final sendTooltip = _sendOnCtrlEnter ? '发送 (Ctrl + Enter)' : '发送 (Enter)';
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        CallbackShortcuts(
          bindings: {
            const SingleActivator(LogicalKeyboardKey.enter): enterAction,
            const SingleActivator(LogicalKeyboardKey.enter, control: true):
                ctrlEnterAction,
            const SingleActivator(LogicalKeyboardKey.numpadEnter): enterAction,
            const SingleActivator(
              LogicalKeyboardKey.numpadEnter,
              control: true,
            ): ctrlEnterAction,
            const SingleActivator(LogicalKeyboardKey.keyV, control: true):
                _paste,
            const SingleActivator(LogicalKeyboardKey.arrowUp):
                ?widget.onSuggestionPrevious,
            const SingleActivator(LogicalKeyboardKey.arrowDown):
                ?widget.onSuggestionNext,
            const SingleActivator(LogicalKeyboardKey.escape):
                ?widget.onSuggestionDismiss,
          },
          child: TextField(
            controller: widget.controller,
            focusNode: widget.focusNode,
            enabled: widget.enabled,
            minLines: 3,
            maxLines: 6,
            keyboardType: TextInputType.multiline,
            textInputAction: TextInputAction.newline,
            decoration: InputDecoration(
              hintText: widget.enabled
                  ? '输入消息，可直接粘贴图片'
                  : '对方离线，暂时无法发送',
              hintStyle: theme.textTheme.bodyMedium?.copyWith(
                color: colorScheme.onSurfaceVariant.withValues(alpha: 0.6),
              ),
              border: InputBorder.none,
              enabledBorder: InputBorder.none,
              focusedBorder: InputBorder.none,
              disabledBorder: InputBorder.none,
              contentPadding: const EdgeInsets.fromLTRB(6, 4, 6, 8),
            ),
          ),
        ),
        const SizedBox(height: 6),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            if (widget.enabled)
              Flexible(
                child: Padding(
                  padding: const EdgeInsets.only(right: 12),
                  child: Text(
                    shortcutHint,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colorScheme.onSurfaceVariant.withValues(
                        alpha: 0.65,
                      ),
                    ),
                  ),
                ),
              ),
            ValueListenableBuilder<TextEditingValue>(
              valueListenable: widget.controller,
              builder: (context, value, _) {
                final ready =
                    widget.enabled &&
                    (value.text.trim().isNotEmpty || widget.hasAttachments);
                final backgroundColor = !widget.enabled
                    ? colorScheme.onSurface.withValues(alpha: 0.1)
                    : ready
                    ? colorScheme.primary
                    : colorScheme.primary.withValues(alpha: 0.45);
                final foregroundColor = !widget.enabled
                    ? colorScheme.onSurface.withValues(alpha: 0.38)
                    : ready
                    ? colorScheme.onPrimary
                    : colorScheme.onPrimary.withValues(alpha: 0.8);
                final arrowColor = !widget.enabled
                    ? colorScheme.onSurface.withValues(alpha: 0.38)
                    : colorScheme.onPrimary.withValues(alpha: ready ? 1.0 : 0.9);
                return ScaleTransition(
                  scale: _sendScale,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 160),
                      curve: Curves.easeOutCubic,
                      height: 34,
                      decoration: BoxDecoration(
                        color: backgroundColor,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Tooltip(
                            message: sendTooltip,
                            child: Material(
                              color: Colors.transparent,
                              child: InkWell(
                                key: const ValueKey('composer-send-button'),
                                onTap: ready ? _triggerSend : null,
                                child: Container(
                                  height: 34,
                                  padding: const EdgeInsets.fromLTRB(
                                    18,
                                    0,
                                    12,
                                    0,
                                  ),
                                  alignment: Alignment.center,
                                  child: Text(
                                    '发送',
                                    style: theme.textTheme.labelLarge?.copyWith(
                                      color: foregroundColor,
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                          Container(
                            width: 1,
                            height: 14,
                            color: arrowColor.withValues(alpha: 0.38),
                          ),
                          Material(
                            color: Colors.transparent,
                            child: PopupMenuButton<bool>(
                              key: const ValueKey('composer-send-mode-button'),
                              enabled: widget.enabled,
                              tooltip: '切换发送快捷键',
                              initialValue: _sendOnCtrlEnter,
                              position: PopupMenuPosition.over,
                              offset: const Offset(0, -104),
                              constraints: const BoxConstraints(
                                minWidth: 200,
                                maxWidth: 320,
                              ),
                              onSelected: _setSendOnCtrlEnter,
                              itemBuilder: (context) => [
                                PopupMenuItem<bool>(
                                  value: false,
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      SizedBox(
                                        width: 20,
                                        child: !_sendOnCtrlEnter
                                            ? Icon(
                                                Icons.check,
                                                size: 16,
                                                color: colorScheme.primary,
                                              )
                                            : null,
                                      ),
                                      const SizedBox(width: 6),
                                      const Flexible(
                                        child: Text('按 Enter 键发送消息'),
                                      ),
                                    ],
                                  ),
                                ),
                                PopupMenuItem<bool>(
                                  value: true,
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      SizedBox(
                                        width: 20,
                                        child: _sendOnCtrlEnter
                                            ? Icon(
                                                Icons.check,
                                                size: 16,
                                                color: colorScheme.primary,
                                              )
                                            : null,
                                      ),
                                      const SizedBox(width: 6),
                                      const Flexible(
                                        child: Text('按 Ctrl + Enter 键发送消息'),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                              child: SizedBox(
                                width: 30,
                                height: 34,
                                child: Center(
                                  child: Icon(
                                    Icons.keyboard_arrow_down,
                                    size: 17,
                                    color: arrowColor,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ],
        ),
      ],
    );
  }

  void _send() {
    if (!widget.enabled || _isComposing) return;
    _triggerSend();
  }

  void _insertNewline() {
    if (!widget.enabled || _isComposing) return;
    final value = widget.controller.value;
    final selection = value.selection.isValid
        ? value.selection
        : TextSelection.collapsed(offset: value.text.length);
    final updatedText = value.text.replaceRange(
      selection.start,
      selection.end,
      '\n',
    );
    widget.controller.value = value.copyWith(
      text: updatedText,
      selection: TextSelection.collapsed(offset: selection.start + 1),
      composing: TextRange.empty,
    );
  }

  Future<void> _paste() async {
    if (!widget.enabled || _isComposing) return;
    final attachmentHandled = await widget.onPasteAttachments?.call() ?? false;
    if (attachmentHandled) return;
    final clipboard = await Clipboard.getData(Clipboard.kTextPlain);
    final text = clipboard?.text;
    if (text == null || text.isEmpty) return;
    _insertText(text);
  }

  void _insertText(String text) {
    final value = widget.controller.value;
    final selection = value.selection.isValid
        ? value.selection
        : TextSelection.collapsed(offset: value.text.length);
    final updatedText = value.text.replaceRange(
      selection.start,
      selection.end,
      text,
    );
    widget.controller.value = value.copyWith(
      text: updatedText,
      selection: TextSelection.collapsed(offset: selection.start + text.length),
      composing: TextRange.empty,
    );
  }

  bool get _isComposing {
    final composing = widget.controller.value.composing;
    return composing.isValid && !composing.isCollapsed;
  }
}
