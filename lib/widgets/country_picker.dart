import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// One country in the dial-code picker: (flag, name, dial code).
typedef Country = (String, String, String);

/// The countries a number can be verified from. Shared by every screen that
/// takes a phone number — sign-in and verify-your-number both read this list,
/// so a country added here appears on both and neither can drift.
const List<Country> countryDialCodes = [
  ('🇺🇸', 'United States', '+1'),
  ('🇨🇦', 'Canada', '+1'),
  ('🇬🇧', 'United Kingdom', '+44'),
  ('🇮🇳', 'India', '+91'),
  ('🇦🇺', 'Australia', '+61'),
  ('🇯🇵', 'Japan', '+81'),
  ('🇩🇪', 'Germany', '+49'),
  ('🇫🇷', 'France', '+33'),
  ('🇧🇷', 'Brazil', '+55'),
  ('🇲🇽', 'Mexico', '+52'),
  ('🇳🇬', 'Nigeria', '+234'),
  ('🇿🇦', 'South Africa', '+27'),
  ('🇦🇪', 'UAE', '+971'),
  ('🇸🇦', 'Saudi Arabia', '+966'),
  ('🇹🇷', 'Türkiye', '+90'),
  ('🇮🇷', 'Iran', '+98'),
  ('🇵🇰', 'Pakistan', '+92'),
  ('🇵🇭', 'Philippines', '+63'),
  ('🇰🇷', 'South Korea', '+82'),
  ('🇨🇳', 'China', '+86'),
];

/// The Telegram-style country sheet. Returns null when dismissed.
Future<Country?> showCountryPicker(BuildContext context) {
  return showModalBottomSheet<Country>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (sheetContext) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.6,
      maxChildSize: 0.9,
      builder: (context, controller) => ListView(
        controller: controller,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(20, 4, 20, 10),
            child: Text('Choose a country',
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
          ),
          for (final c in countryDialCodes)
            ListTile(
              leading: Text(c.$1, style: const TextStyle(fontSize: 24)),
              title: Text(c.$2),
              trailing: Text(c.$3,
                  style: TextStyle(
                      color: AppColors.subtle(context),
                      fontWeight: FontWeight.w600)),
              onTap: () => Navigator.pop(sheetContext, c),
            ),
        ],
      ),
    ),
  );
}
