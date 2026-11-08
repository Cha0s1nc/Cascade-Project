// The desktop engines (Windows, macOS) build their accessibility tree from
// each node's children in traversal order. A node missing from every
// traversal list (an OverlayPortal child whose traversal parent got lost)
// makes the engine pick the wrong root, and closing a dialog then crashes it
// whenever a screen reader is on. So every node must be reachable.
import 'package:cascade/core/settings.dart';
import 'package:cascade/engine/player.dart';
import 'package:cascade/main.dart';
import 'package:cascade/ui/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Nodes the engine could not place: missing from every traversal list, or
/// listed twice.
List<int> lostNodes() {
  final root = RendererBinding.instance.renderViews.first.owner!.semanticsOwner!.rootSemanticsNode!;
  final hit = <int>{}, trav = <int>{}, twice = <int>{};
  void walkHit(SemanticsNode n) {
    hit.add(n.id);
    if (n.mergeAllDescendantsIntoThisNode) return;
    n.visitChildren((c) {
      walkHit(c);
      return true;
    });
  }

  void walkTrav(SemanticsNode n) {
    if (!trav.add(n.id)) twice.add(n.id);
    if (n.mergeAllDescendantsIntoThisNode) return;
    n.debugListChildrenInOrder(DebugSemanticsDumpOrder.traversalOrder).forEach(walkTrav);
  }

  walkHit(root);
  walkTrav(root);
  return [...hit.difference(trav), ...twice];
}

/// Nodes grafted from an OverlayPortal: Cascade's sliders must make none.
List<int> graftedNodes() {
  final root = RendererBinding.instance.renderViews.first.owner!.semanticsOwner!.rootSemanticsNode!;
  final out = <int>[];
  void walk(SemanticsNode n) {
    if (n.getSemanticsData().traversalChildIdentifier != null) out.add(n.id);
    n.visitChildren((c) {
      walk(c);
      return true;
    });
  }

  walk(root);
  return out;
}

void main() {
  testWidgets('a ThinBar under a Tooltip leaves no node out of traversal', (tester) async {
    final semantics = tester.ensureSemantics();
    var volume = 0.5;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: Tooltip(
              message: 'Volume',
              child: SizedBox(width: 96, child: ThinBar(value: volume, onChanged: (v) => volume = v)),
            ),
          ),
        ),
      ),
    );
    expect(lostNodes(), isEmpty);
    expect(graftedNodes(), isEmpty);
    // The one slider node still answers a screen reader.
    final node = find.semantics.byFlag(SemanticsFlag.isSlider).evaluate().single;
    expect(node.value, '50%');
    tester.semantics.performAction(find.semantics.byFlag(SemanticsFlag.isSlider), SemanticsAction.increase);
    expect(volume, closeTo(0.55, 1e-9));
    semantics.dispose();
  });

  testWidgets('the desktop shell and Style menu leave no node out of traversal', (tester) async {
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    final semantics = tester.ensureSemantics();
    final player = Player(audio: false, settings: await Settings.load())..playing = false;
    await tester.pumpWidget(CascadeApp(player: player, demo: true));
    await tester.pumpAndSettle();
    expect(lostNodes(), isEmpty, reason: 'home');
    expect(graftedNodes(), isEmpty, reason: 'home');
    await tester.tap(find.byTooltip('Style').first);
    await tester.pump(const Duration(seconds: 1));
    expect(lostNodes(), isEmpty, reason: 'Style menu');
    expect(graftedNodes(), isEmpty, reason: 'Style menu');
    semantics.dispose();
    await tester.pumpWidget(const SizedBox());
  });
}
