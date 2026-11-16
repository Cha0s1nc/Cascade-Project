// The Electron app's settings controls, shared by Settings and the Style
// menu (see the side-session note electron-ui-spec.md): the 36x20 toggle,
// groups as cards with a caps title and divided rows, the pill tab track
// with its sliding accent pill, and panes that slide sideways as tabs
// change.
import 'package:flutter/material.dart';

import 'package:cascade/ui/widgets.dart';

/// Electron's settings ease, cb(.2,.8,.2,1).
const settingsCurve = Cubic(.2, .8, .2, 1);

/// Electron's popup and editor ease, cb(.2,.7,.3,1).
const editorCurve = Cubic(.2, .7, .3, 1);

/// The 36x20 toggle: surface-2 track, accent when on, a 14px thumb.
class Toggle extends StatefulWidget {
  const Toggle({super.key, required this.value, required this.onChanged});
  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  State<Toggle> createState() => _ToggleState();
}

class _ToggleState extends State<Toggle> {
  bool _focus = false;

  @override
  Widget build(BuildContext context) {
    final off = widget.onChanged == null;
    void flip() => widget.onChanged?.call(!widget.value);
    return Semantics(
      toggled: widget.value,
      enabled: !off,
      child: FocusableActionDetector(
        enabled: !off,
        mouseCursor: off ? SystemMouseCursors.forbidden : SystemMouseCursors.click,
        shortcuts: activateKeys,
        actions: {
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              flip();
              return null;
            },
          ),
        },
        onShowFocusHighlight: (v) => setState(() => _focus = v),
        child: GestureDetector(
          onTap: off ? null : flip,
          child: focusRing(
            on: _focus,
            radius: 10,
            Opacity(
              opacity: off ? 0.45 : 1,
              child: AnimatedContainer(
                duration: Motion.base,
                width: 36,
                height: 20,
                decoration: BoxDecoration(
                  color: widget.value ? K.accent : (K.dark ? K.surface : K.surface2),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: widget.value ? K.accent : K.line),
                ),
                child: AnimatedAlign(
                  duration: Motion.base,
                  curve: Curves.easeOut,
                  alignment: widget.value ? Alignment.centerRight : Alignment.centerLeft,
                  child: Container(
                    width: 14,
                    height: 14,
                    margin: const EdgeInsets.symmetric(horizontal: 2),
                    decoration: BoxDecoration(
                      color: widget.value ? K.ink : Colors.white,
                      shape: BoxShape.circle,
                      // On light, a white thumb on a pale track needs an edge.
                      boxShadow: K.dark ? null : const [BoxShadow(color: Color(0x33000000), blurRadius: 2, offset: Offset(0, 1))],
                    ),
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

/// A group: a card with a caps title over its rows, divided by hairlines.
class SettingsGroup extends StatelessWidget {
  const SettingsGroup(this.title, this.children, {super.key, this.note});
  final String title;
  final List<Widget> children;
  final String? note;

  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.only(bottom: 16),
    clipBehavior: Clip.antiAlias,
    decoration: BoxDecoration(
      color: K.panel,
      borderRadius: BorderRadius.circular(10),
      border: Border.all(color: K.line),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: K.line)),
          ),
          child: Text(
            title.toUpperCase(),
            style: ts(11, w: FontWeight.w600, c: K.text3, ls: 0.66),
          ),
        ),
        for (final (i, c) in children.indexed)
          DecoratedBox(
            decoration: BoxDecoration(
              border: i == children.length - 1 ? null : Border(bottom: BorderSide(color: K.line)),
            ),
            child: c,
          ),
        if (note != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
            child: Text(note!, style: ts(11, c: K.text3)),
          ),
      ],
    ),
  );
}

/// One row: name and description on the left, the control on the right.
class SettingRow extends StatelessWidget {
  const SettingRow(this.title, {super.key, this.subtitle, this.trailing, this.indent = 0, this.enabled = true, this.error = false});
  final String title;
  final String? subtitle;

  /// The subtitle is an error message: red, and read out as it appears.
  final bool error;
  final Widget? trailing;
  final double indent;
  final bool enabled;

  @override
  Widget build(BuildContext context) => Opacity(
    opacity: enabled ? 1 : 0.45,
    child: IgnorePointer(
      ignoring: !enabled,
      child: Padding(
        padding: EdgeInsets.fromLTRB(14 + indent, 11, 14, 11),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: ts(13, w: FontWeight.w500)),
                  if (subtitle != null) ...[
                    const SizedBox(height: 2),
                    Semantics(
                      liveRegion: error,
                      child: Text(subtitle!, style: ts(11, c: error ? K.error : K.text3, h: 1.35)),
                    ),
                  ],
                ],
              ),
            ),
            if (trailing != null) ...[const SizedBox(width: 16), trailing!],
          ],
        ),
      ),
    ),
  );
}

/// A row with a toggle.
class ToggleRow extends StatelessWidget {
  const ToggleRow(this.title, this.value, this.onChanged, {super.key, this.subtitle, this.indent = 0, this.enabled = true});
  final String title;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool>? onChanged;
  final double indent;
  final bool enabled;

  @override
  Widget build(BuildContext context) => SettingRow(
    title,
    subtitle: subtitle,
    indent: indent,
    enabled: enabled,
    trailing: Toggle(value: value, onChanged: onChanged),
  );
}

/// A row with a slider and its value, [width] wide (Electron: 260 in
/// Settings, 196 in the Style menu).
class SliderRow extends StatelessWidget {
  const SliderRow(
    this.title, {
    super.key,
    this.subtitle,
    required this.value,
    required this.min,
    required this.max,
    this.step,
    required this.label,
    required this.onChanged,
    this.width = 260,
    this.enabled = true,
    this.onReset,
  });
  final String title, label;
  final String? subtitle;
  final double value, min, max;
  final double? step;
  final ValueChanged<double> onChanged;
  final double width;
  final bool enabled;
  final VoidCallback? onReset;

  @override
  Widget build(BuildContext context) => SettingRow(
    title,
    subtitle: subtitle,
    enabled: enabled,
    trailing: SizedBox(
      width: width,
      child: Row(
        children: [
          Expanded(
            child: SliderTheme(
              data: SliderThemeData(
                trackHeight: 3,
                activeTrackColor: K.accent,
                inactiveTrackColor: K.line,
                thumbColor: K.text,
                overlayColor: K.accentTint,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
                overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
              ),
              child: safeSlider(
                Slider(
                  value: value.clamp(min, max),
                  min: min,
                  max: max,
                  divisions: step == null ? null : ((max - min) / step!).round().clamp(1, 2000),
                  onChanged: onChanged,
                ),
              ),
            ),
          ),
          SizedBox(
            width: 44,
            child: Text(
              label,
              textAlign: TextAlign.right,
              style: ts(11, c: K.text3),
            ),
          ),
          SizedBox(width: 22, child: onReset == null ? null : IconBtn(Icons.restart_alt_rounded, 'Back to the shipped value', onReset, size: 14)),
        ],
      ),
    ),
  );
}

/// A row with a menu of choices.
class ChoiceRow<T> extends StatelessWidget {
  const ChoiceRow(
    this.title, {
    super.key,
    this.subtitle,
    required this.value,
    required this.items,
    required this.onChanged,
    this.width = 260,
    this.enabled = true,
  });
  final String title;
  final String? subtitle;
  final T value;
  final Map<T, String> items;
  final ValueChanged<T> onChanged;
  final double width;
  final bool enabled;

  @override
  Widget build(BuildContext context) => SettingRow(
    title,
    subtitle: subtitle,
    enabled: enabled,
    trailing: SelectBox<T>(value: value, items: items, onChanged: enabled ? onChanged : null, width: width),
  );
}

/// A desktop select (Electron's <select>): a boxed field with a chevron
/// whose list opens below it, compact rows with a check on the current one.
/// Material's DropdownButton opened its list over the field with tall rows,
/// which read as Android.
class SelectBox<T> extends StatelessWidget {
  const SelectBox({super.key, required this.value, required this.items, required this.onChanged, this.width, this.fill, this.bare = false});
  final T value;
  final Map<T, String> items;
  final ValueChanged<T>? onChanged;
  final double? width;
  final Color? fill;

  /// Inline in a sentence: no box, the text and the chevron only.
  final bool bare;

  @override
  Widget build(BuildContext context) {
    final current = items.containsKey(value) ? value : items.keys.first;
    final on = onChanged != null;
    final label = Text(
      items[current] ?? '',
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: ts(bare ? 13 : 12, c: on ? K.text : K.text3),
    );
    return PopupMenuButton<T>(
      tooltip: '',
      enabled: on,
      position: PopupMenuPosition.under,
      initialValue: current,
      onSelected: (v) => onChanged?.call(v),
      constraints: BoxConstraints(minWidth: width ?? 120, maxHeight: 360),
      itemBuilder: (_) => [
        for (final e in items.entries)
          PopupMenuItem(
            value: e.key,
            height: 32,
            child: Row(
              children: [
                SizedBox(width: 22, child: e.key == current ? Icon(Icons.check_rounded, size: 15, color: K.accent) : null),
                Flexible(child: Text(e.value, style: ts(13))),
              ],
            ),
          ),
      ],
      child: Container(
        width: width,
        padding: EdgeInsets.symmetric(horizontal: bare ? 2 : 10, vertical: bare ? 2 : 7),
        decoration: bare
            ? null
            : BoxDecoration(
                color: fill ?? K.surface,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: K.line),
              ),
        child: Row(
          mainAxisSize: bare ? MainAxisSize.min : MainAxisSize.max,
          children: [
            bare ? label : Expanded(child: label),
            const SizedBox(width: 4),
            Icon(Icons.expand_more_rounded, size: 16, color: K.text2),
          ],
        ),
      ),
    );
  }
}

/// A segmented choice (Electron's seg-control): surface-2 track, the chosen
/// one raised.
class Segmented<T> extends StatelessWidget {
  const Segmented({super.key, required this.value, required this.items, required this.onChanged});
  final T value;
  final Map<T, String> items;
  final ValueChanged<T>? onChanged;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(2),
    decoration: BoxDecoration(
      color: K.surface,
      borderRadius: BorderRadius.circular(7),
      border: Border.all(color: K.line),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      spacing: 2,
      children: [
        for (final MapEntry(:key, value: label) in items.entries)
          Hover(
            onTap: onChanged == null ? null : () => onChanged!(key),
            builder: (_, on) => AnimatedContainer(
              duration: Motion.fast,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              decoration: BoxDecoration(
                color: key == value ? K.panel : Colors.transparent,
                borderRadius: BorderRadius.circular(5),
                boxShadow: key == value ? const [BoxShadow(color: Color(0x33000000), blurRadius: 2, offset: Offset(0, 1))] : null,
              ),
              child: Text(
                label,
                style: ts(11, w: FontWeight.w500, c: key == value || on ? K.text : K.text2),
              ),
            ),
          ),
      ],
    ),
  );
}

/// The pill tab track: tabs in a rounded track with an accent pill that
/// slides and stretches to the chosen one.
class PillTabs extends StatefulWidget {
  const PillTabs({super.key, required this.tabs, required this.value, required this.onChanged, this.small = false});
  final List<(String id, String label, IconData? icon)> tabs;
  final String value;
  final ValueChanged<String> onChanged;
  final bool small;

  @override
  State<PillTabs> createState() => _PillTabsState();
}

class _PillTabsState extends State<PillTabs> {
  final _keys = <String, GlobalKey>{};
  final _track = GlobalKey();
  Rect? _pill;

  @override
  void didUpdateWidget(PillTabs old) {
    super.didUpdateWidget(old);
    WidgetsBinding.instance.addPostFrameCallback((_) => _measure());
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _measure());
  }

  void _measure() {
    final tab = _keys[widget.value]?.currentContext?.findRenderObject() as RenderBox?;
    final track = _track.currentContext?.findRenderObject() as RenderBox?;
    if (tab == null || track == null || !mounted) return;
    final r = tab.localToGlobal(Offset.zero, ancestor: track) & tab.size;
    if (r != _pill) setState(() => _pill = r);
  }

  @override
  Widget build(BuildContext context) => Container(
    key: _track,
    padding: const EdgeInsets.all(3),
    decoration: BoxDecoration(
      color: K.panel,
      borderRadius: BorderRadius.circular(99),
      border: Border.all(color: K.line),
    ),
    child: Stack(
      children: [
        if (_pill != null)
          AnimatedPositioned(
            duration: Motion.slow,
            curve: settingsCurve,
            left: _pill!.left - 3,
            top: 0,
            bottom: 0,
            width: _pill!.width,
            child: Container(
              decoration: BoxDecoration(
                color: K.accent,
                borderRadius: BorderRadius.circular(99),
                boxShadow: [BoxShadow(color: K.accentTint, blurRadius: 10, offset: Offset(0, 2))],
              ),
            ),
          ),
        Row(
          mainAxisSize: MainAxisSize.min,
          spacing: 2,
          children: [
            for (final (id, label, icon) in widget.tabs)
              Hover(
                key: _keys.putIfAbsent(id, GlobalKey.new),
                onTap: () => widget.onChanged(id),
                builder: (_, on) {
                  final c = id == widget.value ? K.ink : (on ? K.text : K.text2);
                  return Padding(
                    padding: EdgeInsets.symmetric(horizontal: widget.small ? 10 : 14, vertical: 6),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (icon != null && !widget.small) ...[Icon(icon, size: 14, color: c), const SizedBox(width: 6)],
                        Text(
                          label,
                          style: ts(12.5, w: FontWeight.w600, c: c),
                        ),
                      ],
                    ),
                  );
                },
              ),
          ],
        ),
      ],
    ),
  );
}

/// Panes that slide sideways as the tab changes (Electron: 320 ms, the
/// incoming pane from the side you moved toward, both fading).
class SlidingPanes extends StatelessWidget {
  const SlidingPanes({super.key, required this.index, required this.child, this.vertical = false});
  final int index;
  final Widget child;

  /// Up and down instead (the Style menu's tabs).
  final bool vertical;

  @override
  Widget build(BuildContext context) => _Panes(index: index, vertical: vertical, child: child);
}

class _Panes extends StatefulWidget {
  const _Panes({required this.index, required this.child, required this.vertical});
  final int index;
  final Widget child;
  final bool vertical;

  @override
  State<_Panes> createState() => _PanesState();
}

class _PanesState extends State<_Panes> {
  int _dir = 1;

  @override
  void didUpdateWidget(_Panes old) {
    super.didUpdateWidget(old);
    if (old.index != widget.index) _dir = widget.index > old.index ? 1 : -1;
  }

  @override
  Widget build(BuildContext context) => ClipRect(
    child: AnimatedSwitcher(
      duration: Motion.slow,
      switchInCurve: settingsCurve,
      // Mirrored: played backward, the plain curve lingers and then whips out.
      switchOutCurve: settingsCurve.flipped,
      layoutBuilder: (current, previous) => Stack(alignment: Alignment.topCenter, children: [...previous, ?current]),
      transitionBuilder: (child, anim) {
        if (calm(context)) return FadeTransition(opacity: anim, child: child);
        final incoming = child.key == ValueKey(widget.index);
        final from = widget.vertical ? Offset(0, 0.06 * _dir) : Offset(_dir.toDouble(), 0);
        final to = widget.vertical ? Offset(0, -0.06 * _dir) : Offset(-_dir.toDouble(), 0);
        return FadeTransition(
          opacity: anim,
          child: SlideTransition(
            position: Tween(begin: incoming ? from : to, end: Offset.zero).animate(anim),
            child: child,
          ),
        );
      },
      child: KeyedSubtree(key: ValueKey(widget.index), child: widget.child),
    ),
  );
}
