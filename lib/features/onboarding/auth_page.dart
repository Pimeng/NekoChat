import 'package:flutter/material.dart';

import '../../app/app_controller.dart';

class AuthPage extends StatefulWidget {
  const AuthPage({super.key, required this.controller});
  final AppController controller;

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

  void _show(String message) =>
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));

  @override
  Widget build(BuildContext context) {
    final setup = widget.controller.stage == AppStage.setup;
    final error = widget.controller.errorMessage;
    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 440),
            child: Card(
              elevation: 2,
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: AutofillGroup(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Icon(Icons.forum_rounded, size: 54),
                      const SizedBox(height: 14),
                      Text(
                        setup ? '创建本机身份' : '解锁 NekoChat',
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.headlineSmall
                            ?.copyWith(fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        setup ? '无需服务器，身份只保存在这台电脑上' : '输入本地密码以恢复身份和聊天记录',
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                      const SizedBox(height: 28),
                      if (setup) ...[
                        TextField(
                          controller: _name,
                          autofocus: true,
                          maxLength: 32,
                          autofillHints: const [AutofillHints.nickname],
                          textInputAction: TextInputAction.next,
                          decoration: const InputDecoration(
                            labelText: '昵称',
                            prefixIcon: Icon(Icons.person_outline),
                          ),
                        ),
                        const SizedBox(height: 12),
                      ],
                      TextField(
                        controller: _password,
                        obscureText: _obscure,
                        autofillHints: const [AutofillHints.password],
                        textInputAction: setup
                            ? TextInputAction.next
                            : TextInputAction.done,
                        onSubmitted: setup ? null : (_) => _submit(),
                        decoration: InputDecoration(
                          labelText: '本地解锁密码',
                          prefixIcon: const Icon(Icons.lock_outline),
                          suffixIcon: IconButton(
                            onPressed: () =>
                                setState(() => _obscure = !_obscure),
                            icon: Icon(
                              _obscure
                                  ? Icons.visibility
                                  : Icons.visibility_off,
                            ),
                          ),
                        ),
                      ),
                      if (setup) ...[
                        const SizedBox(height: 12),
                        TextField(
                          controller: _confirmation,
                          obscureText: _obscure,
                          textInputAction: TextInputAction.done,
                          onSubmitted: (_) => _submit(),
                          decoration: const InputDecoration(
                            labelText: '再次输入密码',
                            prefixIcon: Icon(Icons.lock_reset),
                          ),
                        ),
                        const SizedBox(height: 8),
                        const Text(
                          '密码仅用于解锁本机数据，忘记后无法恢复。至少 4 个字符。',
                          style: TextStyle(fontSize: 12),
                        ),
                      ],
                      if (error != null) ...[
                        const SizedBox(height: 14),
                        Text(
                          error,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                      ],
                      const SizedBox(height: 22),
                      FilledButton.icon(
                        onPressed: _busy ? null : _submit,
                        icon: _busy
                            ? const SizedBox.square(
                                dimension: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : Icon(
                                setup ? Icons.arrow_forward : Icons.lock_open,
                              ),
                        label: Text(setup ? '创建并进入' : '解锁'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
