import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';

import '../../../theme/zzz_colors.dart';
import '../../../widgets/zzz_widgets.dart';
import '../../models/im_models.dart';

class ImLocationSharePanel extends StatefulWidget {
  const ImLocationSharePanel({super.key});

  @override
  State<ImLocationSharePanel> createState() => _ImLocationSharePanelState();
}

class _ImLocationSharePanelState extends State<ImLocationSharePanel> {
  final _name = TextEditingController();
  final _latitude = TextEditingController();
  final _longitude = TextEditingController();
  bool _locating = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _latitude.dispose();
    _longitude.dispose();
    super.dispose();
  }

  Future<void> _useCurrentLocation() async {
    setState(() {
      _locating = true;
      _error = null;
    });
    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        throw StateError('Location services are disabled.');
      }
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        throw StateError('Location permission was not granted.');
      }
      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 15),
        ),
      );
      if (!mounted) return;
      _latitude.text = position.latitude.toStringAsFixed(6);
      _longitude.text = position.longitude.toStringAsFixed(6);
      if (_name.text.trim().isEmpty) _name.text = 'Current location';
    } catch (error) {
      if (mounted) {
        setState(
          () => _error = error.toString().replaceFirst('Bad state: ', ''),
        );
      }
    } finally {
      if (mounted) setState(() => _locating = false);
    }
  }

  void _submit() {
    final name = _name.text.trim();
    final rawLat = _latitude.text.trim();
    final rawLon = _longitude.text.trim();
    if (name.isEmpty) {
      setState(() => _error = 'Enter a place name.');
      return;
    }
    if ((rawLat.isEmpty) != (rawLon.isEmpty)) {
      setState(() => _error = 'Enter both coordinates, or leave both empty.');
      return;
    }
    final lat = rawLat.isEmpty ? null : double.tryParse(rawLat);
    final lon = rawLon.isEmpty ? null : double.tryParse(rawLon);
    if (rawLat.isNotEmpty &&
        (lat == null ||
            lon == null ||
            !lat.isFinite ||
            !lon.isFinite ||
            lat < -90 ||
            lat > 90 ||
            lon < -180 ||
            lon > 180)) {
      setState(() => _error = 'Enter valid latitude and longitude values.');
      return;
    }
    Navigator.of(
      context,
    ).pop(ImLocationShare(name: name, latitude: lat, longitude: lon));
  }

  @override
  Widget build(BuildContext context) {
    return ZzzModalPanel(
      key: const ValueKey('location-share-panel'),
      title: 'Share location',
      subtitle: 'Coordinates are optional',
      icon: Icons.location_on_rounded,
      maxWidth: 480,
      maxHeight: 610,
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton.icon(
          key: const ValueKey('send-shared-location'),
          onPressed: _submit,
          icon: const Icon(Icons.send_rounded),
          label: const Text('Share'),
        ),
      ],
      child: ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.all(18),
        children: [
          ZzzTextInput(
            key: const ValueKey('location-name-field'),
            controller: _name,
            hintText: 'Place name',
            maxLines: 1,
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: ZzzTextInput(
                  key: const ValueKey('location-latitude-field'),
                  controller: _latitude,
                  hintText: 'Latitude',
                  maxLines: 1,
                  keyboardType: const TextInputType.numberWithOptions(
                    signed: true,
                    decimal: true,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: ZzzTextInput(
                  key: const ValueKey('location-longitude-field'),
                  controller: _longitude,
                  hintText: 'Longitude',
                  maxLines: 1,
                  keyboardType: const TextInputType.numberWithOptions(
                    signed: true,
                    decimal: true,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          OutlinedButton.icon(
            key: const ValueKey('use-current-location'),
            onPressed: _locating ? null : _useCurrentLocation,
            icon:
                _locating
                    ? const SizedBox.square(
                      dimension: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                    : const Icon(Icons.my_location_rounded),
            label: const Text('Use current location'),
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(
              _error!,
              key: const ValueKey('location-share-error'),
              style: const TextStyle(color: ZzzColors.red, fontSize: 12),
            ),
          ],
        ],
      ),
    );
  }
}
