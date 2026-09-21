#!/usr/bin/env python3
"""앱 전용 Data Protection Keychain 권한을 프로필과 대조한다."""
import argparse
import datetime
import fnmatch
import hashlib
import pathlib
import plistlib
import re
import shutil
import subprocess


def prepare(profile_path, output_path, identity=None):
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
    if identity:
        identities = subprocess.check_output(["/usr/bin/security", "find-identity", "-v", "-p", "codesigning"]).decode()
        matching = [sha for sha, name in re.findall(r'\)\s+([A-F0-9]{40})\s+"([^"]+)"', identities)
                    if identity == name or identity.upper() == sha]
        certificates = {hashlib.sha1(cert).hexdigest().upper() for cert in profile.get("DeveloperCertificates", [])}
        if len(matching) != 1 or matching[0] not in certificates:
            raise ValueError("프로필에 현재 배포 서명 인증서가 포함돼 있지 않습니다.")
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_bytes(plistlib.dumps({
        "com.apple.application-identifier": app_id,
        "com.apple.developer.team-identifier": team,
        "keychain-access-groups": [app_id],
    }))
    print("앱 전용 Keychain 권한과 프로필 유효기간 확인 완료")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("profile", help="프로필 경로 또는 기존 Xcode 프로필을 재사용할 auto")
    parser.add_argument("output", type=pathlib.Path)
    parser.add_argument("--identity", required=True)
    parser.add_argument("--embed", type=pathlib.Path)
    args = parser.parse_args()
    candidates = [pathlib.Path(args.profile)]
    if args.profile == "auto":
        candidates = [pathlib.Path(__file__).resolve().parent.parent / "packaging/ClaudeSessionWarmer.provisionprofile"]
        for directory in ["Library/Developer/Xcode/UserData/Provisioning Profiles", "Library/MobileDevice/Provisioning Profiles"]:
            candidates.extend(sorted((pathlib.Path.home() / directory).glob("*.provisionprofile"),
                                     key=lambda path: path.stat().st_mtime, reverse=True))
    failure = "일치하는 Developer ID 프로필이 없습니다. PROVISIONING_PROFILE로 경로를 지정해 주세요."
    for candidate in candidates:
        if not candidate.is_file():
            continue
        try:
            prepare(candidate, args.output, args.identity)
            if args.embed:
                args.embed.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(candidate, args.embed)
            break
        except (OSError, ValueError, subprocess.CalledProcessError) as error:
            failure = str(error)
    else:
        parser.exit(1, f"서명 준비 실패: {failure}\n")
