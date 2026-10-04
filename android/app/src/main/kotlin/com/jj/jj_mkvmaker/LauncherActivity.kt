package com.jj.jj_mkvmaker

import android.app.Activity
import android.content.Intent
import android.os.Bundle

/// 앱 목록 · 홈 화면 아이콘 (activity-alias) 이 여는 중계 화면: MainActivity 를 열고 바로 닫는다.
/// MainActivity 작업이 alias 로 시작되면 환경 설정에서 아이콘을 바꿀 때 (그 alias 를 끄면) 앱 화면이 닫히므로.
class LauncherActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        startActivity(Intent(this, MainActivity::class.java).apply {
            action = Intent.ACTION_MAIN
            addCategory(Intent.CATEGORY_LAUNCHER)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        })
        finish()
    }
}
