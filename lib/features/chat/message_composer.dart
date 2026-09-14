import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class MessageComposer extends StatelessWidget {
  const MessageComposer({
    super.key,
    required this.controller,
    required this.enabled,
    required this.onSend,
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

  /// 由外部持有，方便引用回复后立刻把光标送回输入框。
  final FocusNode? focusNode;
  final Future<bool> Function()? onPasteAttachments;
  final VoidCallback? onSuggestionPrevious;
  final VoidCallback? onSuggestionNext;
  final VoidCallback? onSuggestionAccept;
  final VoidCallback? onSuggestionDismiss;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Expanded(
          child: CallbackShortcuts(
            bindings: {
              const SingleActivator(LogicalKeyboardKey.enter):
                  onSuggestionAccept ?? _send,
              const SingleActivator(LogicalKeyboardKey.enter, control: true):
                  _insertNewline,
              const SingleActivator(LogicalKeyboardKey.numpadEnter):
                  onSuggestionAccept ?? _send,
              const SingleActivator(
                LogicalKeyboardKey.numpadEnter,
                control: true,
              ): _insertNewline,
              const SingleActivator(LogicalKeyboardKey.keyV, control: true):
                  _paste,
              const SingleActivator(LogicalKeyboardKey.arrowUp):
                  ?onSuggestionPrevious,
              const SingleActivator(LogicalKeyboardKey.arrowDown):
                  ?onSuggestionNext,
              const SingleActivator(LogicalKeyboardKey.escape):
                  ?onSuggestionDismiss,
            },
            child: TextField(
              controller: controller,
              focusNode: focusNode,
              enabled: enabled,
              minLines: 1,
              maxLines: 5,
              keyboardType: TextInputType.multiline,
              textInputAction: TextInputAction.newline,
              decoration: InputDecoration(
                hintText: enabled
                    ? '输入消息（Enter 发送，Ctrl + Enter 换行，可直接粘贴图片）'
                    : '对方离线，暂时无法发送',
                border: const OutlineInputBorder(),
                isDense: true,
              ),
            ),
          ),
        ),
        const SizedBox(width: 10),
        IconButton.filled(
          tooltip: '发送',
          onPressed: enabled ? onSend : null,
          icon: const Icon(Icons.send),
        ),
      ],
    );
  }

  void _send() {
    if (!enabled || _isComposing) return;
    onSend();
  }

  void _insertNewline() {
    if (!enabled || _isComposing) return;
    final value = controller.value;
    final selection = value.selection.isValid
        ? value.selection
        : TextSelection.collapsed(offset: value.text.length);
    final updatedText = value.text.replaceRange(
      selection.start,
      selection.end,
      '\n',
    );
    controller.value = value.copyWith(
      text: updatedText,
      selection: TextSelection.collapsed(offset: selection.start + 1),
      composing: TextRange.empty,
    );
  }

  Future<void> _paste() async {
    if (!enabled || _isComposing) return;
    final attachmentHandled = await onPasteAttachments?.call() ?? false;
    if (attachmentHandled) return;
    final clipboard = await Clipboard.getData(Clipboard.kTextPlain);
    final text = clipboard?.text;
    if (text == null || text.isEmpty) return;
    _insertText(text);
  }

  void _insertText(String text) {
    final value = controller.value;
    final selection = value.selection.isValid
        ? value.selection
        : TextSelection.collapsed(offset: value.text.length);
    final updatedText = value.text.replaceRange(
      selection.start,
      selection.end,
      text,
    );
    controller.value = value.copyWith(
      text: updatedText,
      selection: TextSelection.collapsed(offset: selection.start + text.length),
      composing: TextRange.empty,
    );
  }

  bool get _isComposing {
    final composing = controller.value.composing;
    return composing.isValid && !composing.isCollapsed;
  }
}
