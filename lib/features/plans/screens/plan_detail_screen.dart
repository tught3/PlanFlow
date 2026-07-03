import 'package:flutter/material.dart';

import '../../../core/constants.dart';
import '../../../core/theme.dart';

/// /plan/:id 라우트에 매핑되는 플랜 상세 화면.
///
/// GoRouter 라우팅 설정(W07)에서 인증 가드 뒤 보호 라우트로 노출된다.
/// 도메인 로직(플랜/태스크 로드)은 추후 Repository 주입으로 확장한다.
class PlanDetailScreen extends StatelessWidget {
  const PlanDetailScreen({super.key, required this.planId});

  /// 라우트 path parameter `id`에서 추출한 플랜 식별자.
  final String planId;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: PlanFlowColors.background,
      appBar: AppBar(title: const Text('플랜 상세')),
      body: Padding(
        padding: const EdgeInsets.all(AppConstants.defaultPadding),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(
                '플랜 #$planId',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: AppConstants.sectionSpacing),
              Text(
                '플랜 상세 내용을 불러오는 기능이 곧 추가됩니다.',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: PlanFlowColors.textSecondary,
                    ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
