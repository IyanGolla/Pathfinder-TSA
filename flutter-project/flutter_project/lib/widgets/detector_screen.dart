import 'package:flutter/material.dart';
import '/models/screen_parameters.dart';
import '/widgets/detector_widget.dart';

/// [DetectorScreen] stacks [DetectorWidget]
class DetectorScreen extends StatelessWidget {
  const DetectorScreen({super.key});

  @override
  Widget build(BuildContext context) {
    ScreenParameters.screenSize = MediaQuery.sizeOf(context);
    return Scaffold(
      key: GlobalKey(),
      backgroundColor: Colors.black,
      appBar: AppBar(
        // title: Image.asset('assets/images/tfl_logo.png', fit: BoxFit.contain),
      ),
      body: const DetectorWidget(),
    );
  }
}
