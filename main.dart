import 'package:flutter/material.dart';
import 'home_screen.dart';

void main() {
  runApp(const ConversationAwarenessApp());
}

class ConversationAwarenessApp extends StatelessWidget {
  const ConversationAwarenessApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Ambient Audio',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF6750A4),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: const HomeScreen(),
    );
  }
}
