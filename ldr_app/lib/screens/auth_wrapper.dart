import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'login_screen.dart';
import 'home_screen.dart';
import 'partner_search_screen.dart';

class AuthWrapper extends StatefulWidget {
  const AuthWrapper({super.key});

  @override
  State<AuthWrapper> createState() => _AuthWrapperState();
}

class _AuthWrapperState extends State<AuthWrapper> {
  bool _isLoading = true;
  bool _isAuthenticated = false;
  bool _hasPartner = false;

  @override
  void initState() {
    super.initState();
    _checkAuth();
    
    // Listen to Auth State Changes
    Supabase.instance.client.auth.onAuthStateChange.listen((data) {
      final session = data.session;
      if (session != null && mounted && !_isAuthenticated) {
        _checkAuth();
      } else if (session == null && mounted) {
        setState(() {
          _isAuthenticated = false;
          _hasPartner = false;
        });
      }
    });
  }

  Future<void> _checkAuth() async {
    final session = Supabase.instance.client.auth.currentSession;
    if (session == null) {
      if (mounted) {
        setState(() {
          _isAuthenticated = false;
          _isLoading = false;
        });
      }
      return;
    }

    // User is logged in, check if they have a partner
    try {
      final res = await Supabase.instance.client
          .from('profiles')
          .select('partner_id')
          .eq('id', session.user.id)
          .maybeSingle();

      if (mounted) {
        setState(() {
          _isAuthenticated = true;
          _hasPartner = res != null && res['partner_id'] != null;
          _isLoading = false;
        });
      }
    } catch (e) {
      debugPrint('Error checking profile: $e');
      if (mounted) {
        setState(() {
          _isAuthenticated = true;
          _hasPartner = false;
          _isLoading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Scaffold(
        body: Center(
          child: CircularProgressIndicator(color: Colors.black),
        ),
      );
    }

    if (!_isAuthenticated) {
      return const LoginScreen();
    }

    if (!_hasPartner) {
      return const PartnerSearchScreen();
    }

    return const HomeScreen();
  }
}
