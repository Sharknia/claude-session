#!/usr/bin/env python3
"""앱 전용 Data Protection Keychain 권한을 프로필과 대조한다."""
import argparse
import datetime
import fnmatch
import pathlib
import plistlib
import subprocess


def prepare(profile_path, output_path):
    profile = plistlib.loads(subprocess.check_output([
        "/usr/bin/security", "cms", "-D", "-i", str(profile_path)
    ]))
    team = "V9SQZ6B7RP"
    bundle = "com.sharknia.ClaudeSessionWarmer"
    allowed = profile.get("Entitlements", {})
    app_id = allowed.get("com.apple.application-identifier", "")
    if not app_id.endswith("." + bundle):
        raise ValueError("이 앱의 명시적 App ID를 가진 프로필이 필요합니다.")
    if team not in profile.get("TeamIdentifier", []):
        raise ValueError("Developer ID 서명 팀과 프로필 팀이 다릅니다.")
    if allowed.get("com.apple.developer.team-identifier") != team or allowed.get("get-task-allow", False):
        raise ValueError("배포용 팀 권한이 일치하지 않거나 디버깅 권한이 켜져 있습니다.")
    if not profile.get("ProvisionsAllDevices"):
        raise ValueError("Developer ID 배포 프로필이 필요합니다.")
    expiry = profile.get("ExpirationDate")
    if not expiry or expiry.replace(tzinfo=datetime.timezone.utc) <= datetime.datetime.now(datetime.timezone.utc):
        raise ValueError("프로비저닝 프로필이 만료됐습니다.")
    if not any(fnmatch.fnmatchcase(app_id, group) for group in allowed.get("keychain-access-groups", [])):
        raise ValueError("프로필이 이 앱의 Keychain 접근 그룹을 허용하지 않습니다.")
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_bytes(plistlib.dumps({
        "com.apple.application-identifier": app_id,
        "com.apple.developer.team-identifier": team,
        "keychain-access-groups": [app_id],
    }))
    print("앱 전용 Keychain 권한과 프로필 유효기간 확인 완료")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("profile", type=pathlib.Path)
    parser.add_argument("output", type=pathlib.Path)
    args = parser.parse_args()
    try:
        prepare(args.profile, args.output)
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"서명 준비 실패: {error}\n")
