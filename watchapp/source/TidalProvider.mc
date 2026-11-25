// Tidal audio content provider for Fenix 8
// - TOF-8: pick one of the user's Tidal playlists on the watch; it syncs
//   DRM-free AAC straight from Tidal's CDN into the encrypted media cache
// - TOF-9: native player with shuffle + repeat (state persisted)
// - TOF-10: storage guards: free-space check per track, tracks that left the
//   active playlist are deleted by their known refs (never by enumeration)
// - diagnostics: on-screen log (Show log) because println is invisible on device

import Toybox.Application;
using Toybox.Communications as Comm;
import Toybox.Graphics;
import Toybox.Lang;
import Toybox.Math;
import Toybox.Media;
import Toybox.PersistedContent;
import Toybox.Timer;
import Toybox.StringUtil;
import Toybox.System;
import Toybox.WatchUi;

class TidalProvider extends Application.AudioContentProviderApp {

    var sync;

    function initialize() {
        AudioContentProviderApp.initialize();
        sync = new Sync();
        if (Application.Storage.getValue("autoLogin_v1") == null) {
            Application.Storage.setValue("autoLogin_v1", true);
            var lgv = new LoginView();
            WatchUi.pushView(lgv, new LoginDelegate(lgv), WatchUi.SLIDE_IMMEDIATE);
        }
    }

    function getPlaybackConfigurationView() as [WatchUi.Views] or [
        WatchUi.Views,
        WatchUi.InputDelegates
    ] {
        var n = Store.targets().size();
        var menu = new WatchUi.Menu2({ :title => "Tidal" });
        menu.addItem(new WatchUi.MenuItem("Play", Store.playName(), :openPlayer, {}));
        menu.addItem(new WatchUi.MenuItem("On watch", n + (n == 1 ? " playlist" : " playlists"), :onWatch, {}));
        menu.addItem(new WatchUi.MenuItem("Browse playlists", "add from Tidal", :browse, {}));
        menu.addItem(new WatchUi.MenuItem("Sync now", "all on watch", :syncNow, {}));
        menu.addItem(new WatchUi.MenuItem("Storage", Sync.storageSummary(), :storage, {}));
        menu.addItem(new WatchUi.MenuItem("Show log", null, :showLog, {}));
        menu.addItem(new WatchUi.MenuItem("Login to Tidal", null, :login, {}));
        menu.addItem(new WatchUi.MenuItem("Remove orphaned tracks", null, :cleanOrphans, {}));
        menu.addItem(new WatchUi.MenuItem("Clear cache", null, :clearCache, {}));
        return [menu, new ConfigInputDelegate(sync) as WatchUi.Menu2InputDelegate];
    }

    function getSyncDelegate() as Comm.SyncDelegate or Null {
        return new TidalSyncDelegate(sync);
    }

    function getContentDelegate(args as Application.PersistableType) as Media.ContentDelegate {
        return new TidalContentDelegate();
    }

    function getProviderIconInfo() as Media.ProviderIconInfo or Null {
        return null;
    }
}

class ConfigInputDelegate extends WatchUi.Menu2InputDelegate {
    var sync;

    function initialize(s) {
        Menu2InputDelegate.initialize();
        sync = s;
    }

    function onSelect(item as WatchUi.MenuItem) as Void {
        var id = item.getId();
        if (id == :login) {
            var lgv = new LoginView();
            WatchUi.pushView(lgv, new LoginDelegate(lgv), WatchUi.SLIDE_IMMEDIATE);
        } else if (id == :browse) {
            PlaylistLoader.open(0);
        } else if (id == :onWatch) {
            OnWatchMenu.open();
        } else if (id == :syncNow) {
            if (Store.targets().size() == 0) {
                PlaylistLoader.open(0);
                return;
            }
            Store.requestSync("MENU: sync now");
        } else if (id == :openPlayer) {
            sync.log("MENU: play " + Store.playName());
            Media.startPlayback(null);
        } else if (id == :storage) {
            sync.showCacheStats();
            item.setSubLabel(Sync.storageSummary());
            WatchUi.requestUpdate();
        } else if (id == :showLog) {
            var lv = new LogView();
            WatchUi.pushView(lv, new LogDelegate(lv), WatchUi.SLIDE_IMMEDIATE);
        } else if (id == :cleanOrphans) {
            sync.cleanOrphanedRefs();
        } else if (id == :clearCache) {
            Media.resetContentCache();
            sync.forgetMappings();
            sync.log("CACHE: reset; exiting app - reopen and re-sync");
            sync.showCacheStats();
            System.exit();
        }
    }
}

// ---------------------------------------------------------------------------
// Playlists on the watch (works offline): play one / all, or remove one
// ---------------------------------------------------------------------------

class OnWatchMenu {
    static function open() as Void {
        var t = Store.targets();
        var menu = new WatchUi.Menu2({ :title => "On watch" });
        if (t.size() == 0) {
            menu.addItem(new WatchUi.MenuItem("(none yet)", "Browse playlists to add", :none, {}));
        }
        if (t.size() > 1) {
            menu.addItem(new WatchUi.MenuItem("All playlists", "play everything", Store.ALL, {}));
        }
        for (var i = 0; i < t.size(); i++) {
            var tid = t[i].get("id").toString();
            menu.addItem(new WatchUi.MenuItem(t[i].get("name").toString(),
                Store.trackCount(tid) + " tracks", tid, {}));
        }
        WatchUi.pushView(menu, new OnWatchDelegate(), WatchUi.SLIDE_IMMEDIATE);
    }
}

class OnWatchDelegate extends WatchUi.Menu2InputDelegate {
    function initialize() {
        Menu2InputDelegate.initialize();
    }

    function onSelect(item as WatchUi.MenuItem) as Void {
        var id = item.getId();
        if (!(id instanceof Lang.String)) {
            return;
        }
        if (id.equals(Store.ALL)) {
            Store.play(Store.ALL);
            return;
        }
        TargetActions.open(id, item.getLabel(), 2);
    }
}

// Play / Remove for one playlist that is on the watch
class TargetActions extends WatchUi.Menu2InputDelegate {
    var tid;
    var name;
    var depth;   // views to pop after remove (stale menus underneath)

    static function open(id, label, popDepth) as Void {
        var menu = new WatchUi.Menu2({ :title => label });
        menu.addItem(new WatchUi.MenuItem("Play", Store.trackCount(id) + " tracks", :play, {}));
        menu.addItem(new WatchUi.MenuItem("Remove from watch", "deletes its songs", :remove, {}));
        WatchUi.pushView(menu, new TargetActions(id, label, popDepth), WatchUi.SLIDE_IMMEDIATE);
    }

    function initialize(id, label, popDepth) {
        Menu2InputDelegate.initialize();
        tid = id;
        name = label;
        depth = popDepth;
    }

    function onSelect(item as WatchUi.MenuItem) as Void {
        var id = item.getId();
        if (id == :play) {
            Store.play(tid);
        } else if (id == :remove) {
            Store.remove(tid);
            PlayLog.log("MENU: removed " + name);
            for (var i = 0; i < depth; i++) {
                WatchUi.popView(WatchUi.SLIDE_IMMEDIATE);
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Which playlists are on the watch. Storage:
//   targets      [{id => "playlist:<uuid>", name => title}, ...]
//   OR_<id>      track ids of that target, in Tidal order (from last sync)
//   playTarget   target id to play, or Store.ALL
//   trackIndex   every track id with DL_<id> (ref) / MT_<id> (metadata)
// A track is deleted only when no target's OR_ list contains it.
// ---------------------------------------------------------------------------

module Store {
    const ALL = "*all";

    function targets() as Lang.Array {
        var t = Application.Storage.getValue("targets");
        if (t != null) {
            return t as Lang.Array;
        }
        // migrate the single-target layout (syncTarget/syncTargetName/order)
        t = [];
        var old = Application.Storage.getValue("syncTarget");
        if (old != null) {
            var nm = Application.Storage.getValue("syncTargetName");
            if (nm == null && old.toString().equals("album:58990510")) {
                nm = "OK Computer";
            }
            t.add({ "id" => old.toString(), "name" => (nm == null ? old.toString() : nm.toString()) });
            var ord = Application.Storage.getValue("order");
            if (ord == null) {
                ord = Application.Storage.getValue("trackIndex");
            }
            if (ord != null) {
                Application.Storage.setValue("OR_" + old.toString(), ord);
            }
            Application.Storage.setValue("playTarget", old.toString());
        }
        Application.Storage.setValue("targets", t);
        Application.Storage.deleteValue("syncTarget");
        Application.Storage.deleteValue("syncTargetName");
        Application.Storage.deleteValue("order");
        return t;
    }

    function indexOf(id) as Lang.Number {
        var t = targets();
        for (var i = 0; i < t.size(); i++) {
            if (t[i].get("id").toString().equals(id.toString())) {
                return i;
            }
        }
        return -1;
    }

    function add(id, name) as Void {
        var t = targets();
        if (indexOf(id) < 0) {
            t.add({ "id" => id.toString(), "name" => name.toString() });
            Application.Storage.setValue("targets", t);
        }
        if (Application.Storage.getValue("playTarget") == null) {
            Application.Storage.setValue("playTarget", id.toString());
        }
    }

    // explicit user action: forget the target and delete songs no other
    // target needs (by known refs; no enumeration)
    function remove(id) as Void {
        var t = targets();
        var out = [] as Lang.Array<Lang.Dictionary>;
        for (var i = 0; i < t.size(); i++) {
            if (!t[i].get("id").toString().equals(id.toString())) {
                out.add(t[i]);
            }
        }
        Application.Storage.setValue("targets", out);
        Application.Storage.deleteValue("OR_" + id);
        var pt = Application.Storage.getValue("playTarget");
        if (pt != null && pt.toString().equals(id.toString())) {
            if (out.size() > 0) {
                Application.Storage.setValue("playTarget", out[0].get("id"));
            } else {
                Application.Storage.deleteValue("playTarget");
            }
        }
        prune();
    }

    function trackCount(id) as Lang.Number {
        var ord = Application.Storage.getValue("OR_" + id);
        return (ord == null) ? 0 : (ord as Lang.Array).size();
    }

    function requestSync(why) as Void {
        PlayLog.log(why);
        Application.Storage.setValue("syncRequest", true);
        Comm.startSync();
    }

    function play(id) as Void {
        Application.Storage.setValue("playTarget", id.toString());
        PlayLog.log("PLAY " + playName());
        Media.startPlayback(null);
    }

    function playName() as Lang.String {
        var t = targets();
        if (t.size() == 0) {
            return "nothing synced";
        }
        var pt = Application.Storage.getValue("playTarget");
        if (pt != null && pt.toString().equals(ALL)) {
            return "All playlists";
        }
        var i = (pt == null) ? -1 : indexOf(pt);
        return t[(i < 0) ? 0 : i].get("name").toString();
    }

    // track ids to play, in order (ALL = every target, first occurrence wins)
    function playOrder() as Lang.Array {
        var t = targets();
        var out = [];
        if (t.size() == 0) {
            return out;
        }
        var pt = Application.Storage.getValue("playTarget");
        if (pt != null && pt.toString().equals(ALL)) {
            var seen = {};
            for (var i = 0; i < t.size(); i++) {
                var ord = Application.Storage.getValue("OR_" + t[i].get("id"));
                if (ord == null) { continue; }
                for (var j = 0; j < ord.size(); j++) {
                    if (!seen.hasKey(ord[j])) {
                        seen.put(ord[j], true);
                        out.add(ord[j]);
                    }
                }
            }
            return out;
        }
        var i = (pt == null) ? -1 : indexOf(pt);
        var ord = Application.Storage.getValue("OR_" + t[(i < 0) ? 0 : i].get("id"));
        return (ord == null) ? out : ord as Lang.Array;
    }

    // delete every downloaded track that no target's OR_ list references
    function prune() as Lang.Number {
        var keep = {};
        var t = targets();
        for (var i = 0; i < t.size(); i++) {
            var ord = Application.Storage.getValue("OR_" + t[i].get("id"));
            if (ord == null) { continue; }
            for (var j = 0; j < ord.size(); j++) {
                keep.put(ord[j], true);
            }
        }
        var idx = Application.Storage.getValue("trackIndex");
        if (idx == null) {
            return 0;
        }
        var kept = [];
        var removed = 0;
        for (var i = 0; i < idx.size(); i++) {
            if (keep.hasKey(idx[i])) {
                kept.add(idx[i]);
            } else {
                removeTrack(idx[i]);
                removed++;
            }
        }
        Application.Storage.setValue("trackIndex", kept);
        if (removed > 0) {
            PlayLog.log("CLEAN: removed " + removed + " tracks");
        }
        return removed;
    }

    function removeTrack(id) as Void {
        var rid = Application.Storage.getValue("DL_" + id);
        if (rid != null) {
            var ref = new Media.ContentRef(rid, Media.CONTENT_TYPE_AUDIO);
            try {
                if (Media.getCachedContentObj(ref) != null) {
                    Media.deleteCachedItem(ref);
                }
            } catch (ex) {
                PlayLog.log("CLEAN: delete " + id + " failed");
            }
        }
        Application.Storage.deleteValue("DL_" + id);
        Application.Storage.deleteValue("MT_" + id);
    }
}

// ---------------------------------------------------------------------------
// TOF-8: playlist picker. JSON requests are fine outside sync mode. Pages of 5
// (~3.3 KB) stay under the makeWebRequest size cap; -402 halves the page.
// ---------------------------------------------------------------------------

class PlaylistLoader {
    const WANT = 10;      // playlists per menu screen

    var view;
    var startOffset;
    var offset;
    var limit = 5;
    var total = null;
    var found = [];
    var cancelled = false;

    // push a loading screen, then switch it to the playlist menu when loaded
    static function open(off) as Void {
        var lv = new LoadingView("Loading playlists...");
        var loader = new PlaylistLoader(off, lv);
        WatchUi.pushView(lv, new LoadingDelegate(loader), WatchUi.SLIDE_IMMEDIATE);
        loader.start();
    }

    function initialize(off, v) {
        startOffset = off;
        offset = off;
        view = v;
    }

    function start() as Void {
        var rt = Application.Storage.getValue("tRefreshToken");
        if (rt == null) {
            view.setStatus("Login to Tidal first");
            return;
        }
        // access tokens live 4 h: always refresh (also yields user id + country)
        var options = {
            :responseType => Comm.HTTP_RESPONSE_CONTENT_TYPE_JSON,
            :method => Comm.HTTP_REQUEST_METHOD_POST,
            :headers => { "Authorization" => TidalAuth.BASIC }
        };
        Comm.makeWebRequest(TidalAuth.AUTH + "/token", TidalUtil.refreshParams(rt), options, method(:onToken));
    }

    function onToken(responseCode as Lang.Number, data as Null or Lang.Dictionary or Lang.String or Lang.ByteArray or PersistedContent.Iterator) as Void {
        if (cancelled) { return; }
        if (responseCode != 200 || data == null) {
            view.setStatus("auth failed " + responseCode);
            PlayLog.log("PL: token refresh " + responseCode);
            return;
        }
        TidalUtil.saveTokens(data);
        fetch();
    }

    function fetch() as Void {
        var uid = Application.Storage.getValue("tUserId");
        if (uid == null) {
            view.setStatus("no user id - login again");
            return;
        }
        var tok = Application.Storage.getValue("tAccessToken");
        var options = {
            :responseType => Comm.HTTP_RESPONSE_CONTENT_TYPE_JSON,
            :method => Comm.HTTP_REQUEST_METHOD_GET,
            :headers => { "Authorization" => "Bearer " + tok.toString() }
        };
        Comm.makeWebRequest(
            TidalAuth.API + "/users/" + uid + "/playlistsAndFavoritePlaylists?countryCode="
            + TidalUtil.country() + "&order=DATE&orderDirection=DESC&limit=" + limit + "&offset=" + offset,
            null, options, method(:onPage));
    }

    function onPage(responseCode as Lang.Number, data as Null or Lang.Dictionary or Lang.String or Lang.ByteArray or PersistedContent.Iterator) as Void {
        if (cancelled) { return; }
        if (responseCode == -402 && limit > 1) {
            limit = limit / 2;
            PlayLog.log("PL: -402, page=" + limit);
            fetch();
            return;
        }
        if (responseCode != 200 || data == null || data.get("items") == null) {
            view.setStatus("list failed " + responseCode);
            PlayLog.log("PL: list failed " + responseCode);
            return;
        }
        var items = data.get("items");
        for (var i = 0; i < items.size(); i++) {
            var e = items[i];
            var pl = (e.get("playlist") != null) ? e.get("playlist") : e;
            if (pl.get("uuid") == null) { continue; }
            found.add({
                "uuid" => pl.get("uuid"),
                "title" => (pl.get("title") == null ? "(untitled)" : pl.get("title")),
                "n" => pl.get("numberOfTracks")
            });
        }
        offset = offset + items.size();
        var t = data.get("totalNumberOfItems");
        if (t != null) { total = t.toNumber(); }
        var more = items.size() > 0 && (total == null || offset < total);
        if (found.size() < WANT && more) {
            fetch();
        } else {
            showMenu(more);
        }
    }

    function showMenu(more) as Void {
        var menu = new WatchUi.Menu2({ :title => "Playlists" });
        if (found.size() == 0) {
            menu.addItem(new WatchUi.MenuItem("(no playlists)", null, :none, {}));
        }
        for (var i = 0; i < found.size(); i++) {
            var p = found[i];
            var n = p.get("n");
            var on = Store.indexOf("playlist:" + p.get("uuid")) >= 0;
            var sub = (on ? "on watch - " : "") + (n == null ? "" : n + " tracks");
            menu.addItem(new WatchUi.MenuItem(p.get("title").toString(), sub,
                p.get("uuid").toString(), {}));
        }
        if (more) {
            var left = (total == null) ? "" : (total - offset) + " more";
            menu.addItem(new WatchUi.MenuItem("More...", left, :more, {}));
        }
        WatchUi.switchToView(menu, new PlaylistMenuDelegate(offset), WatchUi.SLIDE_IMMEDIATE);
    }
}

class PlaylistMenuDelegate extends WatchUi.Menu2InputDelegate {
    var nextOffset;

    function initialize(off) {
        Menu2InputDelegate.initialize();
        nextOffset = off;
    }

    function onSelect(item as WatchUi.MenuItem) as Void {
        var id = item.getId();
        if (id == :more) {
            PlaylistLoader.open(nextOffset);
            return;
        }
        if (id == :none || !(id instanceof Lang.String)) {
            return;
        }
        var tid = "playlist:" + id;
        if (Store.indexOf(tid) >= 0) {
            TargetActions.open(tid, item.getLabel(), 1);
            return;
        }
        Store.add(tid, item.getLabel());
        item.setSubLabel("on watch - syncing");
        Store.requestSync("MENU: add " + item.getLabel());
    }
}

class LoadingView extends WatchUi.View {
    var status;

    function initialize(s) {
        View.initialize();
        status = s;
    }

    function setStatus(s) as Void {
        status = s;
        WatchUi.requestUpdate();
    }

    function onUpdate(dc as Graphics.Dc) as Void {
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_BLACK);
        dc.clear();
        dc.drawText(dc.getWidth() / 2, dc.getHeight() / 2, Graphics.FONT_SMALL, status.toString(),
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
    }
}

class LoadingDelegate extends WatchUi.BehaviorDelegate {
    var loader;

    function initialize(l) {
        BehaviorDelegate.initialize();
        loader = l;
    }

    // a late callback must not switchToView over whatever is on top now
    function onBack() as Boolean {
        loader.cancelled = true;
        WatchUi.popView(WatchUi.SLIDE_IMMEDIATE);
        return true;
    }
}

// ---------------------------------------------------------------------------
// Sync engine. MakeWebRequest AUDIO calls are only valid in sync mode (i.e.
// from within TidalSyncDelegate.onStartSync); JSON requests are fine anywhere.
// Stage machine: refresh token -> page target's track list -> prune tracks no
// longer in the target -> per track (skip synced -> space check -> playback
// info -> CDN audio) -> notify complete.
// ---------------------------------------------------------------------------

class TidalSyncDelegate extends Comm.SyncDelegate {
    var sync;

    function initialize(s) {
        SyncDelegate.initialize();
        sync = s;
    }

    function isSyncNeeded() as Lang.Boolean {
        // only enter sync mode when we asked for it (menu): returning true
        // unconditionally makes a failed sync restart forever
        return Application.Storage.getValue("syncRequest") != null;
    }

    function onStartSync() as Void {
        Application.Storage.deleteValue("syncRequest");
        sync.log("SD.Start");
        sync.startSync();
    }

    function onStopSync() as Void {
        sync.log("SD.Stop");
        sync.finish("cancelled");
    }
}

class Sync {

    static const LOG_MAX = 2000;
    const MAX_TRACKS = 200;            // per playlist; Storage holds MT_/DL_ per track
    const BYTES_PER_SEC = 40000;       // AAC 320 kbps upper bound
    const SPACE_MARGIN = 20000000;     // keep 20 MB free

    static var logStr = "";

    function log(line) as Void {
        PlayLog.log(line);
        logStr = line;
    }

    function brokerBase() as Lang.String {
        return Application.Properties.getValue("BrokerURL");
    }

    function forgetMappings() as Void {
        var idx = Application.Storage.getValue("trackIndex");
        if (idx != null) {
            for (var i = 0; i < idx.size(); i++) {
                Application.Storage.deleteValue("DL_" + idx[i]);
                Application.Storage.deleteValue("MT_" + idx[i]);
            }
        }
        Application.Storage.setValue("trackIndex", []);
        var t = Store.targets();
        for (var i = 0; i < t.size(); i++) {
            Application.Storage.deleteValue("OR_" + t[i].get("id"));
        }
        log("STORAGE: mappings cleared");
    }

    static function storageSummary() as Lang.String {
        var st = Media.getCacheStatistics();
        if (st == null || st.capacity == null) {
            return "unknown";
        }
        var mb = 1048576;
        return (st.size / mb) + " of " + (st.capacity / mb) + " MB used";
    }

    function showCacheStats() as Void {
        var idx = Application.Storage.getValue("trackIndex");
        log("CACHE: " + storageSummary() + ", " + (idx == null ? 0 : idx.size()) + " tracks");
    }

    // a ref maps to metadata iff some DL_<trackId> equals its id; orphans
    // (pre-metadata downloads) have no mapping and no title -> delete them
    function refHasMetadata(ref) as Lang.Boolean {
        var idx = Application.Storage.getValue("trackIndex");
        if (idx == null) {
            return false;
        }
        for (var i = 0; i < idx.size(); i++) {
            var storedRef = Application.Storage.getValue("DL_" + idx[i]);
            if (storedRef != null && storedRef.toString().equals(ref.getId().toString())) {
                return true;
            }
        }
        return false;
    }

    // MANUAL ONLY: enumerates the cache (see AGENTS #1). Never call from sync.
    function cleanOrphanedRefs() as Void {
        var removed = 0;
        var kept = 0;
        try {
            var it = Media.getContentRefIter({ :contentType => Media.CONTENT_TYPE_AUDIO });
            var r = it.next();
            while (r != null) {
                if (refHasMetadata(r)) {
                    kept++;
                } else {
                    Media.deleteCachedItem(r);
                    removed++;
                }
                r = it.next();
            }
        } catch (ex) {
            log("CLEAN error: " + ex.getErrorMessage());
        }
        log("CLEAN: removed " + removed + ", kept " + kept);
        showCacheStats();
    }

    // ---------------- sync state machine ----------------
    // Syncs every target on the watch: fetch each track list (OR_<id>), queue
    // the union (dedup), prune tracks no target references, then download.
    // A target whose list fails keeps its old OR_ list, so its songs survive.

    const MAX_TOTAL = 400;             // across all targets (Storage budget)

    var active = false;    // a sync is running and not yet finished
    var netFails = 0;      // consecutive connectivity failures
    var targets = null;
    var tIdx = 0;
    var seen = null;
    var failedLists = 0;
    var kind = null;       // "playlist" | "album"
    var targetId = null;
    var queue = null;      // array of {id,title,artist,album,duration_s}
    var qIdx = 0;
    var failed = 0;
    var stoppedFull = false;

    function startSync() as Void {
        active = true;
        netFails = 0;
        queue = [];
        seen = {};
        qIdx = 0;
        tIdx = 0;
        failed = 0;
        failedLists = 0;
        stoppedFull = false;
        targets = Store.targets();
        if (targets.size() == 0) {
            log("SYNC: no playlists on watch");
            finish("no playlists on watch");
            return;
        }
        if (Application.Storage.getValue("tRefreshToken") == null) {
            // fallback: pair tokens from the broker once, then go direct
            log("SYNC: no login yet; pairing from broker");
            var popts = {
                :responseType => Comm.HTTP_RESPONSE_CONTENT_TYPE_JSON,
                :method => Comm.HTTP_REQUEST_METHOD_GET
            };
            Comm.makeWebRequest(brokerBase() + "/pair", null, popts, method(:onPaired));
            return;
        }
        syncTokenRefresh();
    }

    function onPaired(responseCode as Lang.Number, data as Null or Lang.Dictionary or Lang.String or Lang.ByteArray or PersistedContent.Iterator) as Void {
        if (!active) { return; }
        if (responseCode != 200 || data == null || data.get("refresh_token") == null) {
            log("SYNC: pairing failed " + responseCode);
            finish("pairing failed " + responseCode.toString());
            return;
        }
        TidalUtil.saveTokens(data);
        syncTokenRefresh();
    }

    function syncTokenRefresh() as Void {
        var options = {
            :responseType => Comm.HTTP_RESPONSE_CONTENT_TYPE_JSON,
            :method => Comm.HTTP_REQUEST_METHOD_POST,
            :headers => { "Authorization" => TidalAuth.BASIC }
        };
        log("SYNC: refreshing token");
        Comm.makeWebRequest(TidalAuth.AUTH + "/token",
            TidalUtil.refreshParams(Application.Storage.getValue("tRefreshToken")),
            options, method(:onTokenRefreshed));
    }

    function onTokenRefreshed(responseCode as Lang.Number, data as Null or Lang.Dictionary or Lang.String or Lang.ByteArray or PersistedContent.Iterator) as Void {
        if (!active) { return; }
        if (responseCode != 200 || data == null || data.get("access_token") == null) {
            log("SYNC: token refresh failed " + responseCode);
            finish("token refresh failed " + responseCode.toString());
            return;
        }
        TidalUtil.saveTokens(data);
        fetchTarget();
    }

    function targetName() as Lang.String {
        return targets[tIdx].get("name").toString();
    }

    // item pages are ~1.3 KB/track: start at 3 (~3.9 KB), shrink on -402
    var listItems = null;
    var listOffset = 0;
    var listLimit = 3;
    var truncated = false;

    function fetchTarget() as Void {
        if (tIdx >= targets.size()) {
            beginDownloads();
            return;
        }
        var tgt = targets[tIdx].get("id").toString();
        var colon = tgt.find(":");
        kind = (colon == null) ? "" : tgt.substring(0, colon);
        if (colon == null || !(kind.equals("playlist") || kind.equals("album"))) {
            log("SYNC: bad target " + tgt);
            failedLists++;
            tIdx++;
            fetchTarget();
            return;
        }
        targetId = tgt.substring(colon + 1, tgt.length());
        listItems = [];
        listOffset = 0;
        listLimit = 3;
        truncated = false;
        fetchListPage();
    }

    function fetchListPage() as Void {
        var tok = Application.Storage.getValue("tAccessToken");
        var options = {
            :responseType => Comm.HTTP_RESPONSE_CONTENT_TYPE_JSON,
            :method => Comm.HTTP_REQUEST_METHOD_GET,
            :headers => { "Authorization" => "Bearer " + tok.toString() }
        };
        var path = kind.equals("album") ? "/albums/" : "/playlists/";
        Comm.makeWebRequest(
            TidalAuth.API + path + targetId + "/items?countryCode=" + TidalUtil.country()
            + "&limit=" + listLimit + "&offset=" + listOffset,
            null, options, method(:onListPage));
    }

    function onListPage(responseCode as Lang.Number, data as Null or Lang.Dictionary or Lang.String or Lang.ByteArray or PersistedContent.Iterator) as Void {
        if (!active) { return; }
        if (responseCode == -402 && listLimit > 1) {
            listLimit = listLimit - 1;
            log("SYNC: -402, page=" + listLimit);
            fetchListPage();
            return;
        }
        if (responseCode != 200 && networkError(responseCode)) {
            return;
        }
        if (responseCode != 200 || data == null || data.get("items") == null) {
            // keep this target's previous OR_ list: its songs stay on the watch
            log("SYNC: list failed " + responseCode + " " + targetName());
            failedLists++;
            tIdx++;
            fetchTarget();
            return;
        }
        netFails = 0;
        var items = data.get("items");
        for (var i = 0; i < items.size() && listItems.size() < MAX_TRACKS; i++) {
            var e = items[i];
            var type = e.get("type");
            if (type != null && !type.toString().equals("track")) {
                continue;  // videos in playlists
            }
            var it = (e.get("item") != null) ? e.get("item") : e;
            var allowed = it.get("allowStreaming");
            if (allowed != null && allowed == false) {
                continue;
            }
            listItems.add({
                "id" => it.get("id"),
                "title" => it.get("title"),
                "artist" => artists(it),
                "album" => (it.get("album") != null) ? it.get("album").get("title") : null,
                "duration_s" => it.get("duration")
            });
        }
        listOffset = listOffset + items.size();
        var total = data.get("totalNumberOfItems");
        var more = items.size() > 0 && (total == null || listOffset < total.toNumber());
        if (more && listItems.size() >= MAX_TRACKS) {
            truncated = true;
            more = false;
        }
        if (more && listOffset < 2000) {
            fetchListPage();
        } else {
            targetDone();
        }
    }

    function targetDone() as Void {
        var order = [];
        for (var i = 0; i < listItems.size(); i++) {
            var t = listItems[i];
            var id = t.get("id");
            order.add(id);
            if (!seen.hasKey(id) && queue.size() < MAX_TOTAL) {
                seen.put(id, true);
                queue.add(t);
            }
        }
        Application.Storage.setValue("OR_" + targets[tIdx].get("id"), order);
        log("SYNC: " + targetName() + " " + order.size() + (truncated ? " (capped)" : ""));
        listItems = null;
        tIdx++;
        fetchTarget();
    }

    function beginDownloads() as Void {
        seen = null;
        log("SYNC: " + queue.size() + " unique tracks");
        Store.prune();
        reportProgress();
        nextTrack();
    }

    function artists(it) as Lang.String {
        var out = "";
        var list = it.get("artists");
        if (list == null) {
            return "";
        }
        for (var i = 0; i < list.size(); i++) {
            if (i > 0) {
                out = out + "; ";
            }
            out = out + list[i].get("name");
        }
        return out;
    }

    function isDownloaded(id) as Lang.Boolean {
        return Application.Storage.getValue("DL_" + id) != null;
    }

    function hasRoomFor(t) as Lang.Boolean {
        var st = Media.getCacheStatistics();
        if (st == null || st.capacity == null || st.capacity == 0) {
            return true;  // no data: don't block
        }
        var dur = t.get("duration_s");
        if (dur == null) {
            dur = 360;
        }
        var need = dur.toLong() * BYTES_PER_SEC + SPACE_MARGIN;
        return (st.capacity - st.size) > need;
    }

    function nextTrack() as Void {
        // skip already-synced tracks
        while (queue != null && qIdx < queue.size() && isDownloaded(queue[qIdx].get("id"))) {
            qIdx++;
        }
        if (queue == null || qIdx >= queue.size()) {
            syncDone();
            return;
        }
        var t = queue[qIdx];
        if (!hasRoomFor(t)) {
            stoppedFull = true;
            log("STORAGE: full at " + qIdx + "/" + queue.size());
            syncDone();
            return;
        }
        var id = t.get("id");
        // store metadata before download so the player shows titles even if the
        // info fetch fails
        setMetadata(id, t);
        reportProgress();
        downloadTrack(id);
    }

    function setMetadata(id, t) as Void {
        var md = {
            "title" => (t.get("title") == null ? "Track " + id : t.get("title")),
            "artist" => (t.get("artist") == null ? "" : t.get("artist")),
            "album" => (t.get("album") == null ? "" : t.get("album")),
            "duration" => (t.get("duration_s") == null ? 0 : t.get("duration_s"))
        };
        Application.Storage.setValue("MT_" + id, md);
        var idx = Application.Storage.getValue("trackIndex");
        if (idx == null) {
            idx = [];
        }
        for (var i = 0; i < idx.size(); i++) {
            if (idx[i].equals(id)) {
                return;
            }
        }
        idx.add(id);
        Application.Storage.setValue("trackIndex", idx);
    }

    function downloadTrack(id) as Void {
        var tok = Application.Storage.getValue("tAccessToken");
        var options = {
            :responseType => Comm.HTTP_RESPONSE_CONTENT_TYPE_JSON,
            :method => Comm.HTTP_REQUEST_METHOD_GET,
            :headers => { "Authorization" => "Bearer " + tok.toString() }
        };
        log("PI [" + qIdx + "/" + queue.size() + "] " + id);
        Comm.makeWebRequest(
            // immersiveaudio=false: Atmos-capable tracks otherwise come back as
            // DOLBY_ATMOS eac3, which the watch can't decode (-1005)
            TidalAuth.API + "/tracks/" + id + "/playbackinfopostpaywall?audioquality=HIGH&playbackmode=STREAM&assetpresentation=FULL&immersiveaudio=false",
            null, options, method(:onPlaybackInfo));
    }

    function skipFailed(msg) as Void {
        log(msg);
        failed++;
        qIdx++;
        reportProgress();
        nextTrack();
    }

    function onPlaybackInfo(responseCode as Lang.Number, data as Null or Lang.Dictionary or Lang.String or Lang.ByteArray or PersistedContent.Iterator) as Void {
        if (!active) { return; }
        var t = (queue != null && qIdx < queue.size()) ? queue[qIdx] : null;
        var id = (t == null) ? "?" : t.get("id");
        if (responseCode != 200 && networkError(responseCode)) {
            return;
        }
        if (responseCode != 200 || data == null || data.get("manifest") == null) {
            skipFailed("ERR PI " + id + " code=" + responseCode);
            return;
        }
        var manifestJson = TidalUtil.b64decode(data.get("manifest"));
        if (manifestJson == null) {
            skipFailed("ERR b64 " + id);
            return;
        }
        if (manifestJson.find("\"NONE\"") == null) {
            skipFailed("ERR " + id + ": encrypted stream");
            return;
        }
        if (manifestJson.find("mp4a") == null) {
            // only AAC plays on the watch; don't download ~20 MB to get -1005
            skipFailed("ERR " + id + ": not AAC");
            return;
        }
        var urls = TidalUtil.manifestUrls(manifestJson);
        if (urls == null || urls.size() == 0) {
            skipFailed("ERR manifest " + id + ": no urls");
            return;
        }
        var audOpts = {
            :responseType => Comm.HTTP_RESPONSE_CONTENT_TYPE_AUDIO,
            :mediaEncoding => Media.ENCODING_M4A,
            :context => id,
            :fileDownloadProgressCallback => method(:onProgress)
        };
        log("DL " + id);
        Comm.makeWebRequest(urls[urls.size() - 1], null, audOpts, method(:onAudioDone));
    }

    function onProgress(totalBytesTransferred as Lang.Number, fileSize as Null or Lang.Number) as Void {
        // per-file progress callbacks are chatty; report whole-list progress instead
    }

    function reportProgress() as Void {
        var pct = 0;
        if (queue != null && queue.size() > 0) {
            pct = (qIdx * 100) / queue.size();
        }
        Comm.notifySyncProgress(pct);
    }

    // The declared data union (fixed by makeWebRequest) omits Media.ContentRef,
    // so `data instanceof Media.ContentRef` is "unreachable" to the type checker
    // and -O2 drops it. Launder through an untyped param to keep the check live.
    function asContentRef(o) as Media.ContentRef or Null {
        if (o instanceof Media.ContentRef) {
            return o as Media.ContentRef;
        }
        return null;
    }

    function onAudioDone(responseCode as Lang.Number, data as Null or Lang.ByteArray or Lang.Dictionary or Lang.String or PersistedContent.Iterator, context as Lang.Object) as Void {
        if (!active) { return; }
        var t = (queue != null && qIdx < queue.size()) ? queue[qIdx] : null;
        var id = (t == null) ? "?" : t.get("id");
        if (responseCode != 200 && networkError(responseCode)) {
            return;
        }
        if (responseCode != 200) {
            skipFailed("ERR " + id + " code=" + responseCode);
            return;
        }
        netFails = 0;
        var cr = asContentRef(data);
        if (cr == null) {
            // never mark downloaded without a ref: retried next sync
            skipFailed("WARN " + id + ": no ref; data=" + (data == null ? "null" : data.toString()));
            return;
        }
        // store the id raw: device ids may be Numbers, toString() breaks lookup
        var rid = cr.getId() as Lang.Object;
        if (rid instanceof Lang.Number) {
            Application.Storage.setValue("DL_" + id, rid as Lang.Number);
        } else if (rid instanceof Lang.String) {
            Application.Storage.setValue("DL_" + id, rid as Lang.String);
        } else {
            Application.Storage.setValue("DL_" + id, cr.getId().toString());
        }
        log("OK " + id);
        qIdx++;
        nextTrack();
    }

    function syncDone() as Void {
        log("SYNC: done, failed=" + failed + (failedLists > 0 ? " lists=" + failedLists : ""));
        showCacheStats();
        var msg = null;
        if (stoppedFull) {
            msg = "storage full";
        } else if (failedLists > 0) {
            msg = failedLists + " playlists failed";
        } else if (failed > 0) {
            msg = failed + " tracks failed";
        }
        finish(msg);
    }

    // Exactly-once end of a sync (SDK: notifySyncComplete must be called once,
    // on success or error). After this every late callback is ignored, so a
    // cancelled/aborted sync never issues more requests.
    function finish(msg) as Void {
        if (!active) {
            return;
        }
        active = false;
        Comm.cancelAllRequests();
        Comm.notifySyncComplete(msg);
    }

    // connectivity-level failures (negative codes other than the size caps)
    // mean Wi-Fi is gone: stop instead of failing every remaining track
    function networkError(code) as Lang.Boolean {
        if (code == -5) {          // REQUEST_CANCELLED: our own stop/abort
            finish("cancelled");
            return true;
        }
        if (code < 0 && code != -402 && code != -403) {
            netFails++;
            if (netFails >= 3) {
                log("SYNC: network lost (" + code + "), stopping");
                finish("network lost");
                return true;
            }
        }
        return false;
    }
}

// persisted log usable from every context (config, sync, playback)
module PlayLog {
    function log(line) as Void {
        System.println(line);
        var s = Application.Storage.getValue("log");
        s = (s == null ? "" : s.toString()) + line + "\n";
        if (s.length() > Sync.LOG_MAX) {
            s = s.substring(s.length() - Sync.LOG_MAX, s.length());
        }
        Application.Storage.setValue("log", s);
    }
}

// ---------------------------------------------------------------------------
// Player content (TOF-9: shuffle + repeat)
// The system calls onShuffle/onRepeat on the delegate, then reads the state
// back through the iterator's shuffling()/repeatMode() — so the delegate keeps
// its iterator and mutates it in place.
// ---------------------------------------------------------------------------

class TidalContentDelegate extends Media.ContentDelegate {
    var iter = null;

    function initialize() {
        ContentDelegate.initialize();
    }

    function getContentIterator() as Media.ContentIterator or Null {
        iter = new TidalIterator();
        return iter;
    }

    function resetContentIterator() as Media.ContentIterator or Null {
        iter = new TidalIterator();
        return iter;
    }

    function onShuffle() as Void {
        var on = !(Application.Storage.getValue("shuffle") == true);
        Application.Storage.setValue("shuffle", on);
        if (iter != null) {
            iter.setShuffle(on);
        }
        PlayLog.log("SHUFFLE " + (on ? "on" : "off"));
    }

    function onRepeat() as Void {
        var cur = Application.Storage.getValue("repeat");
        var nxt = Media.REPEAT_MODE_ALL;
        if (cur == Media.REPEAT_MODE_ALL) {
            nxt = Media.REPEAT_MODE_ONE;
        } else if (cur == Media.REPEAT_MODE_ONE) {
            nxt = Media.REPEAT_MODE_OFF;
        }
        Application.Storage.setValue("repeat", nxt as Lang.Number);
        if (iter != null) {
            iter.setRepeat(nxt);
        }
        PlayLog.log("REPEAT " + nxt);
    }

    function onSong(contentRefId, songEvent, playbackPosition) as Void {
        PlayLog.log("EVT " + songEvent + " @" + playbackPosition);
    }
}

class TidalIterator extends Media.ContentIterator {
    var ids = [] as Lang.Array<Lang.Object>;          // Tidal track ids, playlist order
    var refs = [] as Lang.Array<Media.ContentRef>;    // matching ContentRefs
    var seq = [] as Lang.Array<Lang.Number>;          // play order: indices into ids/refs
    var pos = 0;         // index into seq
    var shuffle = false;
    var repeat = Media.REPEAT_MODE_OFF;

    function initialize() {
        ContentIterator.initialize();
        // Build the playlist from our own storage mapping. The system
        // ContentRefIterator can throw uncatchable VM errors, so never use it.
        var order = Store.playOrder();
        if (order.size() > 0) {
            for (var i = 0; i < order.size(); i++) {
                var rid = Application.Storage.getValue("DL_" + order[i]);
                if (rid == null) { continue; }
                ids.add(order[i]);
                refs.add(new Media.ContentRef(rid, Media.CONTENT_TYPE_AUDIO));
            }
        }
        shuffle = (Application.Storage.getValue("shuffle") == true);
        var r = Application.Storage.getValue("repeat");
        if (r != null) {
            repeat = r;
        }
        buildSeq(-1);
        PlayLog.log("ITER: " + Store.playName() + " " + refs.size() + (shuffle ? " shuf" : "") + " rep" + repeat);
    }

    // keep = index (into ids) of the track that should stay current, or -1
    function buildSeq(keep) as Void {
        var n = refs.size();
        seq = [] as Lang.Array<Lang.Number>;
        for (var i = 0; i < n; i++) {
            seq.add(i);
        }
        pos = 0;
        if (shuffle && n > 1) {
            Math.srand(System.getTimer());
            for (var i = n - 1; i > 0; i--) {
                var j = (Math.rand() % (i + 1)).abs();
                var tmp = seq[i];
                seq[i] = seq[j];
                seq[j] = tmp;
            }
            if (keep >= 0) {
                // current track first, so toggling shuffle doesn't jump
                for (var i = 0; i < n; i++) {
                    if (seq[i] == keep) {
                        seq[i] = seq[0];
                        seq[0] = keep;
                        break;
                    }
                }
            }
        } else if (keep >= 0) {
            pos = keep;
        }
    }

    function setShuffle(on) as Void {
        var cur = (pos >= 0 && pos < seq.size()) ? seq[pos] : -1;
        shuffle = on;
        buildSeq(cur);
    }

    function setRepeat(m) as Void {
        repeat = m;
    }

    function lookup(ref) {
        try {
            return Media.getCachedContentObj(ref);
        } catch (ex) {
            return null;  // exceptions are catchable here; VM errors are not
        }
    }

    function contentAt(p) {
        if (p < 0 || p >= seq.size()) {
            return null;
        }
        var i = seq[p];
        var ref = refs[i];
        var content = lookup(ref);
        if (content == null) {
            // legacy storage held toString()'d ids; retry with the other type
            var rid = ref.getId();
            var alt = null;
            if (rid instanceof Lang.String) {
                alt = rid.toNumber();
            } else if (rid != null) {
                alt = rid.toString();
            }
            if (alt != null) {
                var altRef = new Media.ContentRef(alt, Media.CONTENT_TYPE_AUDIO);
                content = lookup(altRef);
                if (content != null) {
                    refs[i] = altRef;
                }
            }
        }
        if (content == null) {
            PlayLog.log("ITER: no obj " + ids[i]);
            return null;
        }
        var stored = Application.Storage.getValue("MT_" + ids[i]) as Lang.Dictionary or Null;
        if (stored != null) {
            var md = content.getMetadata();
            if (md == null) {
                md = new Media.ContentMetadata();
            }
            md.title = stored.get("title");
            md.artist = stored.get("artist");
            md.album = stored.get("album");
            // getMetadata() may hand back a copy: write it back explicitly
            content.setMetadata(md);
        }
        return content;
    }

    // REPEAT_ONE: next/previous stay on the current track (the iterator can't
    // tell a user skip from end-of-track). Turn repeat off to skip.
    function nextPos() {
        var n = seq.size();
        if (n == 0) { return -1; }
        if (repeat == Media.REPEAT_MODE_ONE) { return pos; }
        if (pos + 1 < n) { return pos + 1; }
        return (repeat == Media.REPEAT_MODE_ALL) ? 0 : -1;
    }

    function prevPos() {
        var n = seq.size();
        if (n == 0) { return -1; }
        if (repeat == Media.REPEAT_MODE_ONE) { return pos; }
        if (pos > 0) { return pos - 1; }
        return (repeat == Media.REPEAT_MODE_ALL) ? n - 1 : -1;
    }

    function get() as Media.Content or Null {
        return contentAt(pos);
    }

    function next() as Media.Content or Null {
        var p = nextPos();
        if (p < 0) { return null; }
        pos = p;
        return contentAt(pos);
    }

    function peekNext() as Media.Content or Null {
        var p = nextPos();
        return (p < 0) ? null : contentAt(p);
    }

    function previous() as Media.Content or Null {
        var p = prevPos();
        if (p < 0) { return null; }
        pos = p;
        return contentAt(pos);
    }

    function peekPrevious() as Media.Content or Null {
        var p = prevPos();
        return (p < 0) ? null : contentAt(p);
    }

    function getPlaybackProfile() as Media.PlaybackProfile or Null {
        var profile = new Media.PlaybackProfile();
        // first entry = hardware hotkey (bottom-left button on Fenix 8):
        // user wants next-track there, not play/pause
        profile.playbackControls = [
            Media.PLAYBACK_CONTROL_NEXT,
            Media.PLAYBACK_CONTROL_PLAYBACK,
            Media.PLAYBACK_CONTROL_PREVIOUS,
            Media.PLAYBACK_CONTROL_SHUFFLE,
            Media.PLAYBACK_CONTROL_REPEAT
        ];
        return profile;
    }

    function canSkip() as Lang.Boolean {
        return true;
    }

    function shuffling() as Lang.Boolean {
        return shuffle;
    }

    function repeatMode() as Media.RepeatMode or Null {
        return repeat;
    }
}

// ---------------------------------------------------------------------------
// On-screen log
// ---------------------------------------------------------------------------

class LogView extends WatchUi.View {
    var back = 0;   // lines scrolled back from the newest

    function initialize() {
        View.initialize();
    }

    function scroll(d) as Void {
        back = back + d;
        if (back < 0) { back = 0; }
        WatchUi.requestUpdate();
    }

    function onUpdate(dc as Graphics.Dc) as Void {
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_BLACK);
        dc.clear();
        var cx = dc.getWidth() / 2;
        var s = Application.Storage.getValue("log");
        if (s == null) {
            s = "";
        }
        var h = dc.getHeight();
        dc.setColor(Graphics.COLOR_ORANGE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, 30, Graphics.FONT_XTINY, back > 0 ? "LOG -" + back + " (UP/DN)" : "TIDAL LOG (UP/DN)", Graphics.TEXT_JUSTIFY_CENTER);
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        if (s.length() == 0) {
            dc.drawText(cx, h / 2, Graphics.FONT_XTINY, "(no output)", Graphics.TEXT_JUSTIFY_CENTER);
            return;
        }
        // String.find() takes no start offset — slice suffixes instead
        var lines = [];
        var rest = s;
        while (rest.length() > 0) {
            var nl = rest.find("\n");
            if (nl == null) {
                lines.add(rest);
                rest = "";
            } else {
                if (nl > 0) {
                    lines.add(rest.substring(0, nl));
                }
                rest = rest.substring(nl + 1, rest.length());
            }
        }
        var count = lines.size();
        var maxShow = 8;
        if (back > count - maxShow) { back = count > maxShow ? count - maxShow : 0; }
        var skip = count > maxShow ? count - maxShow - back : 0;
        var shown = count > maxShow ? maxShow : count;
        var y = h / 2 - shown * 22 / 2;
        var end = skip + maxShow < count ? skip + maxShow : count;
        for (var i = skip; i < end; i++) {
            var l = lines[i];
            if (l.length() > 24) {
                l = l.substring(0, 24);
            }
            dc.drawText(cx, y, Graphics.FONT_XTINY, l, Graphics.TEXT_JUSTIFY_CENTER);
            y = y + 22;
        }
    }
}

class LogDelegate extends WatchUi.BehaviorDelegate {
    var view;
    function initialize(v) {
        BehaviorDelegate.initialize();
        view = v;
    }
    function onPreviousPage() as Boolean {  // UP: older lines
        view.scroll(1);
        return true;
    }
    function onNextPage() as Boolean {      // DOWN: newer lines
        view.scroll(-1);
        return true;
    }
}

class LoginDelegate extends WatchUi.BehaviorDelegate {
    var view;
    function initialize(v) {
        BehaviorDelegate.initialize();
        view = v;
    }
    // Views never receive onBack; route it so the poll timer is stopped
    function onBack() as Boolean {
        return view.onBack();
    }
}

// ---------------------------------------------------------------------------
// Tidal constants + utilities
// ---------------------------------------------------------------------------
module TidalAuth {
    const CLIENT_ID = "4N3n6Q1x95LL5K7p";
    const BASIC = "Basic NE4zbjZRMXg5NUxMNUs3cDpvS09YZkpXMzcxY1g2eGFaMFB5aGdHTkJkTkxsQlpkNEFLS1lvdWdNamlrPQ==";
    const AUTH = "https://auth.tidal.com/v1/oauth2";
    const API = "https://api.tidal.com/v1";
    const B64T = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
}

module TidalUtil {

    function refreshParams(rt) as Lang.Dictionary {
        return {
            "client_id" => TidalAuth.CLIENT_ID,
            "refresh_token" => rt.toString(),
            "grant_type" => "refresh_token",
            "scope" => "r_usr+w_usr+w_sub"
        };
    }

    // token responses (device-code poll, refresh, broker /pair) carry
    // user_id + user.countryCode alongside the tokens
    function saveTokens(data) as Void {
        var at = data.get("access_token");
        if (at != null) { Application.Storage.setValue("tAccessToken", at); }
        var rt = data.get("refresh_token");
        if (rt != null) { Application.Storage.setValue("tRefreshToken", rt); }
        var ex = data.get("expires_in");
        if (ex != null) { Application.Storage.setValue("tExpiresIn", ex); }
        var uid = data.get("user_id");
        if (uid != null) { Application.Storage.setValue("tUserId", uid); }
        var u = data.get("user");
        if (u instanceof Lang.Dictionary) {
            if (uid == null && u.get("userId") != null) {
                Application.Storage.setValue("tUserId", u.get("userId"));
            }
            if (u.get("countryCode") != null) {
                Application.Storage.setValue("tCountry", u.get("countryCode"));
            }
        }
    }

    function country() as Lang.String {
        var cc = Application.Storage.getValue("tCountry");
        return (cc == null) ? "US" : cc.toString();
    }

    function b64decode(s) as Lang.String or Null {
        var tbl = TidalAuth.B64T;
        var out = [] as Array<Char>;
        var acc = 0;
        var nbits = 0;
        var raw;
        try {
            raw = s.toString();
        } catch (ex) {
            return null;
        }
        for (var i = 0; i < raw.length(); i++) {
            var ch = raw.substring(i, i + 1);
            if (ch.equals("=")) { break; }  // padding: end of payload
            var idx = tbl.find(ch);
            if (idx == null) {
                return null;
            }
            acc = (acc * 64) + idx;
            nbits = nbits + 6;
            if (nbits >= 8) {
                nbits = nbits - 8;
                var byte = ((acc >> nbits) & 255);
                acc = acc & ((1 << nbits) - 1);
                out.add(byte.toChar());
            }
        }
        return StringUtil.charArrayToString(out);
    }

    function manifestUrls(manifestJson) as Lang.Array or Null {
        var urls = [];
        var keyPos = manifestJson.find("\"urls\":[");
        if (keyPos == null) {
            return null;
        }
        var i = keyPos + 7;
        var len = manifestJson.length();
        while (i < len) {
            var q1 = manifestJson.substring(i, i + 1);
            if (q1 == null || q1.equals("]")) { break; }
            if (!q1.equals("\"")) {
                i++;
                continue;
            }
            var j = i + 1;
            var url = "";
            while (j < len) {
                var c = manifestJson.substring(j, j + 1);
                if (c == null || c.equals("\"")) { break; }
                if (!c.equals("\\")) { url = url + c; }
                j++;
            }
            if (j >= len) { break; }  // unterminated string
            urls.add(url);
            i = j + 1;
        }
        return urls;
    }
}

// ---------------------------------------------------------------------------
// Tidal OAuth device-code login, entirely on the watch
// ---------------------------------------------------------------------------
class LoginView extends WatchUi.View {
    var pollTimer;
    var deviceCode = null;
    var status = "requesting device code...";
    var userCode = "";

    function initialize() {
        View.initialize();
        var options = {
            :responseType => Comm.HTTP_RESPONSE_CONTENT_TYPE_JSON,
            :method => Comm.HTTP_REQUEST_METHOD_POST
        };
        var params = { "client_id" => TidalAuth.CLIENT_ID, "scope" => "r_usr+w_usr+w_sub" };
        Comm.makeWebRequest(TidalAuth.AUTH + "/device_authorization", params, options, method(:onDeviceAuth));
    }

    function setPoller(running) as Void {
        if (pollTimer != null) {
            pollTimer.stop();
        }
        pollTimer = running;
    }

    function onDeviceAuth(responseCode as Lang.Number, data as Null or Lang.Dictionary or Lang.String or Lang.ByteArray or PersistedContent.Iterator) as Void {
        if (responseCode != 200 || data == null) {
            status = "device_auth failed: " + responseCode;
            WatchUi.requestUpdate();
            return;
        }
        deviceCode = data.get("deviceCode");
        userCode = data.get("userCode");
        var interval = data.get("interval");
        if (interval == null || interval < 5) {
            interval = 5;
        }
        status = "waiting...";
        WatchUi.requestUpdate();
        pollTimer = new Timer.Timer();
        pollTimer.start(method(:pollToken), interval * 1000, true);
    }

    function pollToken() as Void {
        if (deviceCode == null) {
            return;
        }
        var options = {
            :responseType => Comm.HTTP_RESPONSE_CONTENT_TYPE_JSON,
            :method => Comm.HTTP_REQUEST_METHOD_POST,
            :headers => { "Authorization" => TidalAuth.BASIC }
        };
        var params = {
            "client_id" => TidalAuth.CLIENT_ID,
            "device_code" => deviceCode.toString(),
            "grant_type" => "urn:ietf:params:oauth:grant-type:device_code",
            "scope" => "r_usr+w_usr+w_sub"
        };
        Comm.makeWebRequest(TidalAuth.AUTH + "/token", params, options, method(:onPoll));
    }

    function onPoll(responseCode as Lang.Number, data as Null or Lang.Dictionary or Lang.String or Lang.ByteArray or PersistedContent.Iterator) as Void {
        if (responseCode != 200) {
            var err = (data != null && data.get("error") != null) ? data.get("error").toString() : "";
            if (err.equals("slow_down")) {
                // Tidal rate control: back off and keep polling
                pollTimer.stop();
                pollTimer.start(method(:pollToken), 8 * 1000, true);
                status = "waiting (slowed)";
            } else if (!err.equals("authorization_pending")) {
                status = "error: " + err;
                setPoller(null);
            } else {
                status = "waiting...";
            }
            WatchUi.requestUpdate();
            return;
        }
        TidalUtil.saveTokens(data);
        status = "logged in!";
        setPoller(null);
        WatchUi.requestUpdate();
    }

    function onUpdate(dc as Graphics.Dc) as Void {
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_BLACK);
        dc.clear();
        var cx = dc.getWidth() / 2;
        dc.setColor(Graphics.COLOR_ORANGE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, 34, Graphics.FONT_XTINY, "TIDAL LOGIN v2", Graphics.TEXT_JUSTIFY_CENTER);
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, dc.getHeight() / 2 - 20, Graphics.FONT_LARGE, userCode.toString(), Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
        dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, dc.getHeight() / 2 + 35, Graphics.FONT_XTINY, "link.tidal.com", Graphics.TEXT_JUSTIFY_CENTER);
        dc.drawText(cx, dc.getHeight() / 2 + 55, Graphics.FONT_XTINY, status.toString(), Graphics.TEXT_JUSTIFY_CENTER);
        dc.setColor(Graphics.COLOR_DK_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, dc.getHeight() - 24, Graphics.FONT_XTINY, "BACK when logged in", Graphics.TEXT_JUSTIFY_CENTER);
    }

    function onBack() as Boolean {
        setPoller(null);
        WatchUi.popView(WatchUi.SLIDE_IMMEDIATE);
        return true;
    }
}
