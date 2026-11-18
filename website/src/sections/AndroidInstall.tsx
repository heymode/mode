/* Installing on Android (#android). Every "Mode for Android" link on the site comes here, not to the APK:
   Play Protect blocks a browser, messaging app or file manager from installing an app that declares an
   accessibility service, and Mode needs one to tap for you. So the APK is offered only inside a route.

   Words: marketing's android-install.md (v1.1, 16 Nov). Which routes show, and in what order: ROUTE_ORDER, one line.
   A route whose phone check hasn't passed must be taken out of ROUTE_ORDER before the site deploys. */
import { useMemo, type ReactNode } from 'react';
import { withVisitor } from '../lib/analytics';
import { ANDROID_HREF, isAndroid } from '../lib/platform';
import { REPO } from '../links';

type RouteId = 'obtainium' | 'computer' | 'pause';

/** The routes shown, first to last. Obtainium needs check C5a to pass, the computer route C5b; the pause route
    passed on the owner's OnePlus (16 Nov) and stays last (cto, staff-engineer). */
const ROUTE_ORDER: RouteId[] = ['obtainium', 'computer', 'pause'];

/** The route tagged "Recommended": set only once the owner has chosen one (and its phone check passed). null shows no tag. */
const RECOMMENDED: RouteId | null = null;

/** Shows its children only on an Android phone (where the "Open in Obtainium" button is shown). */
function OnAndroid({ children }: { children: ReactNode }) {
  const android = useMemo(isAndroid, []);
  return android ? <>{children}</> : null;
}

const out = (href: string, target: string, label: ReactNode) => (
  <a href={href} target="_blank" rel="noopener" data-ev="out_click" data-where="android" data-target={target}>{label}</a>
);
const apk = (where: string, label: ReactNode = <code>mode-android.apk</code>) => (
  <a href={withVisitor(ANDROID_HREF, where)} data-ev="download_click" data-where={where} data-target="android">{label}</a>
);
const samsung = <>Samsung phones: switch off <b>Auto Blocker</b> first. It is usually under Settings &gt; Security and privacy &gt; Auto Blocker, and you confirm with your PIN or fingerprint. It also blocks commands over a USB cable.</>;

/** `action` is a button under the steps; `androidOnly` hides it on computers and iPhones, where it can't work. */
const ROUTES: Record<RouteId, { title: string; intro: ReactNode; steps: ReactNode[]; after?: ReactNode; action?: ReactNode; androidOnly?: boolean }> = {
  obtainium: {
    title: 'Install with Obtainium',
    intro: 'Obtainium is a free, open-source app that installs apps from GitHub the way a store does.',
    steps: [
      <>Install Obtainium from its {out('https://github.com/ImranR98/Obtainium/releases', 'obtainium', 'releases page')}.</>,
      <>Open Obtainium and tap <b>Add app</b><OnAndroid>, or tap <b>Open in Obtainium</b> below and skip to step 4</OnAndroid>.</>,
      <>Paste <code>https://github.com/heymode/mode</code> and tap <b>Add</b>.</>,
      <>Tap <b>Install</b> on Mode.</>,
      <>Open Mode and follow the setup steps.</>,
    ],
    after: 'Obtainium also tells you when there’s a new version of Mode.',
    action: <a className="btn soft" href="obtainium://add/https://github.com/heymode/mode" data-ev="out_click" data-where="android" data-target="obtainium-add">Open in Obtainium</a>,
    androidOnly: true,
  },
  computer: {
    title: 'Install from a computer',
    intro: 'For people who already use developer tools. It takes about five minutes.',
    steps: [
      <>On the phone, turn on <b>Developer options</b> (Settings &gt; About phone, tap <b>Build number</b> seven times), then turn on <b>USB debugging</b>.</>,
      <>On the computer, install Google’s {out('https://developer.android.com/tools/releases/platform-tools', 'platform-tools', 'Android platform-tools')}.</>,
      <>Download {apk('android-computer')} on the computer.</>,
      <>Plug in the phone and allow the computer when the phone asks.</>,
      <>Run: <code>adb install mode-android.apk</code></>,
      <>Open Mode and follow the setup steps.</>,
    ],
    after: samsung,
  },
  pause: {
    title: 'Pause Play Protect while you install',
    intro: <>This works on any phone, but it means switching off a safety feature for a minute. Only do it for apps you trust, and <b>turn it back on straight after</b>.</>,
    steps: [
      <>Download {apk('android-pause')}.</>,
      <>Open the <b>Play Store</b>, tap your profile picture, then <b>Play Protect</b> &gt; <b>Settings</b> (the gear).</>,
      <>Turn off <b>Scan apps with Play Protect</b>.</>,
      <>Open the downloaded file and tap <b>Install</b>.</>,
      <><b>Go back and turn Scan apps with Play Protect on again.</b></>,
      <>Open Mode and follow the setup steps. Android locks Phone control for apps installed from a browser, and Mode walks you through unlocking it, in the order Android needs: first tap <b>Mode</b> in Settings &gt; Accessibility once (Android says it was denied; tap <b>Close</b>), then in Mode’s App info tap <b>⋮</b> &gt; <b>Allow restricted settings</b>, then turn Mode on in Accessibility.</>,
    ],
    after: 'Google will never ask you to turn Play Protect off on a phone call, and nor will we. If anyone does, it’s a scam.',
  },
};

export function AndroidInstall() {
  const android = useMemo(isAndroid, []);
  return (
    <section className="wrap" id="android" data-section="android" aria-labelledby="android-h" style={{ scrollMarginTop: 'calc(24px + var(--sat))' }}>
      <div className="droid setup rv">
        <ul className="pills"><li className="now">Android 13 or later · free · open source</li></ul>
        <h2 id="android-h">Installing <em>on Android.</em></h2>
        <p><b>Short version:</b> if you download Mode in your browser and tap the file, Android will probably block it. Use one of the routes below instead.</p>
        <p>Google Play Protect blocks apps that are downloaded in a browser, a messaging app or a file manager and that use an accessibility service. Scam apps abuse that service, so Google blocks every app that uses it unless it comes from a store or another trusted route. The message says “App blocked to protect your device”, and it has no “Install anyway” button.</p>
        <p>Mode needs the accessibility service. It’s how Mode sees the screen and taps for you, which is the whole product. Mode is open source, so you can <a href={REPO} target="_blank" rel="noopener" data-ev="github_click" data-where="android">read exactly what it does</a> with it. Google Play doesn’t allow this kind of agent, so Mode isn’t on the Play Store.</p>
        <ol className="routes">
          {ROUTE_ORDER.map((id) => {
            const r = ROUTES[id];
            return (
              <li key={id} data-route={id}>
                <h3>{r.title}{id === RECOMMENDED && <span className="rec">Recommended</span>}</h3>
                <span className="who">{r.intro}</span>
                <ol>{r.steps.map((s, j) => <li key={j}>{s}</li>)}</ol>
                {r.after && <span className="who">{r.after}</span>}
                {r.action && (android || !r.androidOnly) && <div className="row">{r.action}</div>}
              </li>
            );
          })}
        </ol>
        <p className="need">You need Android 13 or later. Background mode needs Android 14 and Wi-Fi. <b>Something didn’t work?</b> Tell us your phone model and what you saw <a href={`${REPO}/issues`} target="_blank" rel="noopener" data-ev="github_click" data-where="android">on GitHub</a>.</p>
      </div>
    </section>
  );
}
