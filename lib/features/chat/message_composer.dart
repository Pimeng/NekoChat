import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class MessageComposer extends StatelessWidget {
  const MessageComposer({
    super.key,
    required this.controller,
    required this.enabled,
    required this.onSend,
  });

  final TextEditingController controller;
  final bool enabled;
  final VoidCallback onSend;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Expanded(
          child: CallbackShortcuts(
            bindings: {
              const SingleActivator(LogicalKeyboardKey.enter): _send,
              const SingleActivator(LogicalKeyboardKey.enter, control: true):
                  _insertNewline,
              const SingleActivator(LogicalKeyboardKey.numpadEnter): _send,
              const SingleActivator(
                LogicalKeyboardKey.numpadEnter,
                control: true,
              ): _insertNewline,
            },
            child: TextField(
              controller: controller,
              enabled: enabled,
              minLines: 1,
              maxLines: 5,
              keyboardType: TextInputType.multiline,
              textInputAction: TextInputAction.newline,
              decoration: InputDecoration(
                hintText: enabled
                    ? '输入消息（Enter 发送，Ctrl + Enter 换行）'
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

  bool get _isComposing {
    final composing = controller.value.composing;
    return composing.isValid && !composing.isCollapsed;
  }
}
