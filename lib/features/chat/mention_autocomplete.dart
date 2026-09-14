import 'dart:async';

import 'package:flutter/material.dart';

import 'message_composer.dart';

class MentionCandidate {
  const MentionCandidate({
    required this.deviceId,
    required this.displayName,
    required this.insertionName,
    this.originalName,
  });

  final String deviceId;
  final String displayName;
  final String insertionName;
  final String? originalName;
}

/// 群聊输入框：输入 @ 后在输入框上方展示成员候选，并支持键盘/鼠标选择。
class MentionAutocomplete extends StatefulWidget {
  const MentionAutocomplete({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.enabled,
    required this.onSend,
    required this.loadCandidates,
    this.onPasteAttachments,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final bool enabled;
  final VoidCallback onSend;
  final Future<List<MentionCandidate>> Function() loadCandidates;
  final Future<bool> Function()? onPasteAttachments;

  @override
  State<MentionAutocomplete> createState() => _MentionAutocompleteState();
}

class _MentionAutocompleteState extends State<MentionAutocomplete> {
  final ScrollController _suggestionScroll = ScrollController();
  List<MentionCandidate> _allCandidates = const [];
  List<MentionCandidate> _filteredCandidates = const [];
  int _selectedIndex = 0;
  int? _triggerStart;
  int _triggerEnd = 0;
  String _query = '';
  String? _dismissedText;
  bool _loading = false;
  int _loadGeneration = 0;

  bool get _menuOpen =>
      _triggerStart != null && _dismissedText != widget.controller.text;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_handleTextChanged);
    _handleTextChanged();
  }

  @override
  void didUpdateWidget(covariant MentionAutocomplete oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_handleTextChanged);
      widget.controller.addListener(_handleTextChanged);
      _resetCandidates();
      _handleTextChanged();
    }
  }

  @override
  void dispose() {
    _loadGeneration++;
    widget.controller.removeListener(_handleTextChanged);
    _suggestionScroll.dispose();
    super.dispose();
  }

  void _resetCandidates() {
    _allCandidates = const [];
    _filteredCandidates = const [];
    _loading = false;
  }

  void _handleTextChanged() {
    if (!mounted) return;
    final wasOpen = _triggerStart != null;
    final trigger = _mentionTrigger(widget.controller.value);
    final changed = trigger?.query != _query || trigger?.start != _triggerStart;
    setState(() {
      _triggerStart = trigger?.start;
      _triggerEnd = trigger?.end ?? 0;
      _query = trigger?.query ?? '';
      if (_dismissedText != null && _dismissedText != widget.controller.text) {
        _dismissedText = null;
      }
      if (changed) _selectedIndex = 0;
      _filterCandidates();
    });
    if (trigger != null && (!wasOpen || _allCandidates.isEmpty) && !_loading) {
      unawaited(_loadCandidates());
    }
  }

  Future<void> _loadCandidates() async {
    final generation = ++_loadGeneration;
    setState(() => _loading = true);
    List<MentionCandidate> candidates;
    try {
      candidates = await widget.loadCandidates();
    } on Object {
      candidates = const [];
    }
    if (!mounted || generation != _loadGeneration) return;
    setState(() {
      _loading = false;
      _allCandidates = candidates;
      _filterCandidates();
      _selectedIndex = 0;
    });
  }

  void _filterCandidates() {
    final normalized = _query.trim().toLowerCase();
    _filteredCandidates = [
      for (final candidate in _allCandidates)
        if (normalized.isEmpty ||
            candidate.displayName.toLowerCase().contains(normalized) ||
            candidate.insertionName.toLowerCase().contains(normalized))
          candidate,
    ];
    if (_filteredCandidates.isEmpty) {
      _selectedIndex = 0;
    } else if (_selectedIndex >= _filteredCandidates.length) {
      _selectedIndex = _filteredCandidates.length - 1;
    }
  }

  void _moveSelection(int delta) {
    if (_filteredCandidates.isEmpty) return;
    setState(() {
      _selectedIndex =
          (_selectedIndex + delta + _filteredCandidates.length) %
          _filteredCandidates.length;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_suggestionScroll.hasClients) return;
      const itemExtent = 52.0;
      final target = _selectedIndex * itemExtent;
      final position = _suggestionScroll.position;
      final visibleStart = position.pixels;
      final visibleEnd = visibleStart + position.viewportDimension - itemExtent;
      if (target < visibleStart || target > visibleEnd) {
        _suggestionScroll.animateTo(
          target.clamp(position.minScrollExtent, position.maxScrollExtent),
          duration: const Duration(milliseconds: 100),
          curve: Curves.easeOut,
        );
      }
    });
  }

  void _acceptSelected() {
    if (!_menuOpen || _filteredCandidates.isEmpty) return;
    _insertCandidate(_filteredCandidates[_selectedIndex]);
  }

  void _insertCandidate(MentionCandidate candidate) {
    final start = _triggerStart;
    if (start == null) return;
    final value = widget.controller.value;
    final mention = '@${candidate.insertionName} ';
    final updated = value.text.replaceRange(start, _triggerEnd, mention);
    widget.controller.value = value.copyWith(
      text: updated,
      selection: TextSelection.collapsed(offset: start + mention.length),
      composing: TextRange.empty,
    );
    widget.focusNode.requestFocus();
  }

  void _dismiss() => setState(() => _dismissedText = widget.controller.text);

  @override
  Widget build(BuildContext context) {
    final composing = widget.controller.value.composing;
    final composingActive = composing.isValid && !composing.isCollapsed;
    final keyboardActive =
        _menuOpen && _filteredCandidates.isNotEmpty && !composingActive;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_menuOpen) _buildSuggestions(context),
        MessageComposer(
          controller: widget.controller,
          focusNode: widget.focusNode,
          enabled: widget.enabled,
          onSend: widget.onSend,
          onPasteAttachments: widget.onPasteAttachments,
          onSuggestionPrevious: keyboardActive
              ? () => _moveSelection(-1)
              : null,
          onSuggestionNext: keyboardActive ? () => _moveSelection(1) : null,
          onSuggestionAccept: _menuOpen && !composingActive
              ? _acceptSelected
              : null,
          onSuggestionDismiss: _menuOpen ? _dismiss : null,
        ),
      ],
    );
  }

  Widget _buildSuggestions(BuildContext context) {
    final count = _filteredCandidates.length;
    return Container(
      key: const ValueKey('mention-suggestions'),
      constraints: const BoxConstraints(maxHeight: 240),
      margin: const EdgeInsets.only(bottom: 6),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Theme.of(context).dividerColor),
        boxShadow: const [
          BoxShadow(
            color: Colors.black26,
            blurRadius: 12,
            offset: Offset(0, 4),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: _loading && _allCandidates.isEmpty
          ? const SizedBox(
              height: 52,
              child: Center(
                child: SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            )
          : count == 0
          ? const SizedBox(height: 52, child: Center(child: Text('没有匹配的群成员')))
          : ListView.builder(
              controller: _suggestionScroll,
              shrinkWrap: true,
              itemExtent: 52,
              itemCount: count,
              itemBuilder: (context, index) {
                final candidate = _filteredCandidates[index];
                final selected = index == _selectedIndex;
                return MouseRegion(
                  onEnter: (_) => setState(() => _selectedIndex = index),
                  child: InkWell(
                    onTap: () => _insertCandidate(candidate),
                    child: ColoredBox(
                      color: selected
                          ? Theme.of(context).colorScheme.primary
                                .withValues(alpha: .14)
                          : Colors.transparent,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                        child: Row(
                          children: [
                            CircleAvatar(
                              radius: 14,
                              child: Text(
                                _avatarText(candidate.displayName),
                                style: const TextStyle(fontSize: 11),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    candidate.displayName,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  if (candidate.originalName != null)
                                    Text(
                                      '原名：${candidate.originalName}',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: Theme.of(context)
                                          .textTheme
                                          .labelSmall,
                                    ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
    );
  }

  static ({int start, int end, String query})? _mentionTrigger(
    TextEditingValue value,
  ) {
    final selection = value.selection;
    if (!selection.isValid || !selection.isCollapsed) return null;
    final cursor = selection.extentOffset;
    if (cursor < 0 || cursor > value.text.length) return null;
    var start = cursor;
    while (start > 0) {
      final previous = value.text.codeUnitAt(start - 1);
      if (previous == 0x20 || previous == 0x0A || previous == 0x09) break;
      start--;
    }
    if (start >= cursor || value.text.codeUnitAt(start) != 0x40) return null;
    final query = value.text.substring(start + 1, cursor);
    if (query.contains('@')) return null;
    return (start: start, end: cursor, query: query);
  }
}

String _avatarText(String value) {
  final normalized = value.trim();
  if (normalized.isEmpty) return '?';
  return normalized.characters.first.toUpperCase();
}
