import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class MessageComposer extends StatefulWidget {
  const MessageComposer({
    super.key,
    required this.controller,
    required this.enabled,
    required this.onSend,
    this.hasAttachments = false,
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

  @override
  void dispose() {
    _sendPulse.dispose();
    super.dispose();
  }

  void _triggerSend() {
    if (!widget.enabled) return;
    _sendPulse.forward(from: 0);
    widget.onSend();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Expanded(
          child: CallbackShortcuts(
            bindings: {
              const SingleActivator(LogicalKeyboardKey.enter):
                  widget.onSuggestionAccept ?? _send,
              const SingleActivator(LogicalKeyboardKey.enter, control: true):
                  _insertNewline,
              const SingleActivator(LogicalKeyboardKey.numpadEnter):
                  widget.onSuggestionAccept ?? _send,
              const SingleActivator(
                LogicalKeyboardKey.numpadEnter,
                control: true,
              ): _insertNewline,
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
              minLines: 1,
              maxLines: 5,
              keyboardType: TextInputType.multiline,
              textInputAction: TextInputAction.newline,
              decoration: InputDecoration(
                hintText: widget.enabled
                    ? '输入消息（Enter 发送，Ctrl + Enter 换行，可直接粘贴图片）'
                    : '对方离线，暂时无法发送',
                border: const OutlineInputBorder(),
                isDense: true,
              ),
            ),
          ),
        ),
        const SizedBox(width: 10),
        ValueListenableBuilder<TextEditingValue>(
          valueListenable: widget.controller,
          builder: (context, value, _) {
            final ready =
                widget.enabled &&
                (value.text.trim().isNotEmpty || widget.hasAttachments);
            return ScaleTransition(
              scale: _sendScale,
              child: AnimatedScale(
                duration: const Duration(milliseconds: 160),
                curve: Curves.easeOutCubic,
                scale: ready ? 1.0 : 0.94,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  curve: Curves.easeOutCubic,
                  decoration: BoxDecoration(
                    color: !widget.enabled
                        ? colorScheme.onSurface.withValues(alpha: 0.12)
                        : ready
                        ? colorScheme.primary
                        : colorScheme.primaryContainer,
                    shape: BoxShape.circle,
                  ),
                  child: IconButton(
                    tooltip: '发送',
                    onPressed: widget.enabled ? _triggerSend : null,
                    color: !widget.enabled
                        ? colorScheme.onSurface.withValues(alpha: 0.38)
                        : ready
                        ? colorScheme.onPrimary
                        : colorScheme.onPrimaryContainer,
                    icon: const Icon(Icons.send, size: 20),
                  ),
                ),
              ),
            );
          },
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
