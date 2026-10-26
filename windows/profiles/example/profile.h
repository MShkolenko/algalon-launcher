// Realm profile for forever-launcher.cpp. Everything that names one realm lives here; the launcher code names none.
// Build with:  build.cmd example
// A template: copy this folder to profiles/<yours>, fill in your realm, then build.cmd <yours>.
#pragma once

#define REALM_SERVER      L"localhost"         // host the hosts line points the portal name at (resolved at launch)
#define REALM_PORTAL      L"example"           // the client portal: example.actual.battle.net
#define REALM_CONFIG      L"Example.wtf"       // WTF\<config>, the launcher's own settings file; Config.wtf is untouched
#define REALM_NAME       L"Example"           // short name in messages
#define REALM_LONG_NAME  L"Example Realm"     // %LOCALAPPDATA% folder, hosts comment, CA name in messages
#define REALM_LONG_NAME_A "Example Realm"
#define REALM_ID          L"example"           // file and folder names: <id>-launcher, _forever_<id>_, hosts.bak-<id>-*
#define REALM_ID_A        "example"
#define REALM_MUTEX_ID    L"Example"           // Global\<id>LauncherHostsEdit, Local\<id>Launcher

// Your realm's CA certificate (PEM, public part only). It must carry a critical nameConstraints extension that
// permits only DNS:<portal>.actual.battle.net, so it can vouch for nothing else. Empty here: a launcher built from
// this template fails with an error at the CA step until you put your own certificate in (the hosts line may
// already have been written by then).
#define REALM_CA_PEM ""

// Update feed (docs/update-feed.md): your repository and your ECDSA P-256 public key (64 bytes X||Y in hex, made with
// tools/sign_manifest.py --new-key). Empty: no self-update.
#define REALM_UPDATE_REPO   L""
#define REALM_UPDATE_PUBKEY L""
