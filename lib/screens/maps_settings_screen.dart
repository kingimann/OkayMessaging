import 'package:flutter/material.dart';

import '../app_state.dart';
import '../widgets/osm_map.dart';

/// Every Maps preference in one place: base style, units, low data mode,
/// voice guidance, and the default travel mode for directions.
class MapsSettingsScreen extends StatelessWidget {
  const MapsSettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Maps settings')),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          _label(context, 'MAP STYLE'),
          ValueListenableBuilder<String>(
            valueListenable: AppState.mapLayer,
            builder: (context, name, _) => Column(
              children: [
                for (final l in MapLayer.values)
                  ListTile(
                    dense: true,
                    leading: Icon(l.icon),
                    title: Text(l.label),
                    trailing: MapLayer.fromName(name) == l
                        ? Icon(Icons.check,
                            color: Theme.of(context).colorScheme.primary)
                        : null,
                    onTap: () => AppState.mapLayer.value = l.name,
                  ),
              ],
            ),
          ),
          const Divider(),
          _label(context, 'DISTANCES'),
          ValueListenableBuilder<String>(
            valueListenable: AppState.mapUnits,
            builder: (context, units, _) => Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: SegmentedButton<String>(
                segments: const [
                  ButtonSegment(
                      value: 'metric', label: Text('Kilometres')),
                  ButtonSegment(value: 'imperial', label: Text('Miles')),
                ],
                selected: {units},
                showSelectedIcon: false,
                onSelectionChanged: (s) =>
                    AppState.mapUnits.value = s.first,
              ),
            ),
          ),
          const SizedBox(height: 8),
          const Divider(),
          _label(context, 'NAVIGATION'),
          ValueListenableBuilder<bool>(
            valueListenable: AppState.navVoice,
            builder: (context, on, _) => SwitchListTile.adaptive(
              secondary: const Icon(Icons.record_voice_over_outlined),
              title: const Text('Voice guidance'),
              subtitle: const Text('Speak each turn during navigation'),
              value: on,
              onChanged: (v) => AppState.navVoice.value = v,
            ),
          ),
          ValueListenableBuilder<String>(
            valueListenable: AppState.defaultTravelMode,
            builder: (context, mode, _) => Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Directions open with',
                      style: TextStyle(
                          fontSize: 13, color: Theme.of(context).colorScheme.onSurfaceVariant)),
                  const SizedBox(height: 6),
                  SegmentedButton<String>(
                    segments: const [
                      ButtonSegment(
                          value: 'car',
                          icon: Icon(Icons.directions_car),
                          label: Text('Drive')),
                      ButtonSegment(
                          value: 'foot',
                          icon: Icon(Icons.directions_walk),
                          label: Text('Walk')),
                      ButtonSegment(
                          value: 'bike',
                          icon: Icon(Icons.directions_bike),
                          label: Text('Cycle')),
                    ],
                    selected: {mode},
                    showSelectedIcon: false,
                    onSelectionChanged: (s) =>
                        AppState.defaultTravelMode.value = s.first,
                  ),
                ],
              ),
            ),
          ),
          const Divider(),
          _label(context, 'DATA'),
          ValueListenableBuilder<bool>(
            valueListenable: AppState.mapLowData,
            builder: (context, low, _) => SwitchListTile.adaptive(
              secondary: const Icon(Icons.data_saver_on_outlined),
              title: const Text('Low data mode'),
              subtitle: const Text('Lighter tiles for slow connections'),
              value: low,
              onChanged: (v) => AppState.mapLowData.value = v,
            ),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  Widget _label(BuildContext context, String text) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
        child: Text(text,
            style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.6,
                color: Colors.grey)),
      );
}
