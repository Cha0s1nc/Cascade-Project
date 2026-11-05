// The player bar's and title bar's panel buttons: Announcements, Waterfall,
// Miniplayer and Devices. Each opens its own panel.
import 'package:flutter/material.dart';

import 'package:cascade/ui/widgets.dart';

class AnnouncementsButton extends StatelessWidget {
  const AnnouncementsButton({super.key});

  @override
  Widget build(BuildContext context) => const IconBtn(Icons.notifications_none_rounded, 'Announcements', null);
}

class WaterfallButton extends StatelessWidget {
  const WaterfallButton({super.key});

  @override
  Widget build(BuildContext context) => const IconBtn(Icons.water_drop_outlined, 'Waterfall, listen together', null);
}

class MiniplayerButton extends StatelessWidget {
  const MiniplayerButton({super.key});

  @override
  Widget build(BuildContext context) => const IconBtn(Icons.picture_in_picture_alt_outlined, 'Miniplayer', null);
}

class DevicesButton extends StatelessWidget {
  const DevicesButton({super.key});

  @override
  Widget build(BuildContext context) => const IconBtn(Icons.cast_rounded, 'Connect to a device', null);
}
