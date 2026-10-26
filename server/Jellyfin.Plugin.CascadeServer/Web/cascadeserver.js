// The Cascade Server dashboard page (status.html, styled by cascadeserver.css).
// Uses Jellyfin's own ApiClient, so every request is the signed-in admin's.
(function () {
    var page = (document.currentScript && document.currentScript.closest('[data-role="page"]')) ||
        document.querySelector('#CascadeServerStatusPage');
    // A view Jellyfin keeps in its cache runs this again on a later visit.
    if (!page || page.csInit) return;
    page.csInit = true;

    var PLUGIN_ID = 'a8b9c0d1-e2f3-4a5b-6c7d-8e9f0a1b2c3d';
    var app = page.querySelector('.cs-app');
    var $ = function (sel) { return page.querySelector(sel); };

    function escapeHtml(str) {
        return String(str == null ? '' : str).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
    }
    // Guids compared without dashes or case, however they were saved.
    function normId(id) { return String(id || '').replace(/-/g, '').toLowerCase(); }
    function setStatus(el, text, kind) {
        el.textContent = text || '';
        el.className = 'cs-status' + (kind ? ' ' + kind : '');
    }
    // A failed ApiClient call hands back a Response; its body says why.
    function errorText(res, fallback) {
        if (res && typeof res.json === 'function') {
            return res.json().then(function (j) { return (j && j.error) || fallback; }, function () { return fallback; });
        }
        return Promise.resolve(fallback);
    }

    // -- Tabs ------------------------------------------------------------
    function placePill() {
        var active = $('.cs-tab.active');
        var pill = $('.cs-pill');
        if (!active || !active.offsetWidth) return;
        pill.style.width = active.offsetWidth + 'px';
        pill.style.transform = 'translateX(' + (active.offsetLeft - 3) + 'px)';
    }
    function showTab(name) {
        app.setAttribute('data-tab', name);
        page.querySelectorAll('.cs-tab').forEach(function (t) {
            var on = t.getAttribute('data-tab') === name;
            t.classList.toggle('active', on);
            t.setAttribute('aria-selected', on ? 'true' : 'false');
        });
        page.querySelectorAll('.cs-pane').forEach(function (p) {
            p.classList.toggle('active', p.getAttribute('data-pane') === name);
        });
        placePill();
    }
    page.querySelectorAll('.cs-tab').forEach(function (t) {
        t.addEventListener('click', function () { showTab(t.getAttribute('data-tab')); });
    });
    window.addEventListener('resize', placePill);

    // -- Settings (the plugin's configuration, saved together) -----------
    function renderUserList(target, cls, users, allowed) {
        var set = {};
        (allowed || []).forEach(function (id) { set[normId(id)] = true; });
        $(target).innerHTML = users.map(function (u) {
            var admin = !!(u.Policy && u.Policy.IsAdministrator);
            return '<label class="cs-row"><span class="cs-label"><span class="cs-name">' + escapeHtml(u.Name) +
                (admin ? '<span class="cs-tag">Administrator, always allowed</span>' : '') + '</span></span>' +
                '<span class="cs-toggle"><input type="checkbox" class="' + cls + '" data-id="' + escapeHtml(u.Id) + '"' +
                (admin || set[normId(u.Id)] ? ' checked' : '') + (admin ? ' disabled' : '') + ' /><span class="cs-track"></span></span></label>';
        }).join('') || '<div class="cs-empty">No users.</div>';
    }

    function loadSettings() {
        return Promise.all([ApiClient.getPluginConfiguration(PLUGIN_ID), ApiClient.getUsers()]).then(function (r) {
            var config = r[0];
            var users = r[1] || [];
            $('#csDisableSidecarWrites').checked = !!config.DisableSidecarWrites;
            $('#csSpicyKey').value = config.SpicyLyricsSecretKey || '';
            renderUserList('#csLinkUsers', 'csLinkUser', users, config.ServerWideSpotifyLinkUsers);
            renderUserList('#csExplicitUsers', 'csExplicitUser', users, config.ExplicitEditUsers);
            $('#csExplicitDeezer').checked = config.ExplicitLookupDeezer !== false;
            $('#csExplicitItunes').checked = config.ExplicitLookupItunes !== false;
            $('#csMirrorExplicitTag').checked = !!config.MirrorExplicitTag;
            renderUserList('#csArtUsers', 'csArtUser', users, config.AnimatedArtEditUsers);
            $('#csArtOrder').value = config.AnimatedArtSourceOrder || 'sidecar-first';
            $('#csArtNames').value = (config.AnimatedArtSidecarNames || ['cover.mp4', 'cover.webm']).join(', ');
            $('#csArtMaxMb').value = config.AnimatedArtMaxUploadMb || 50;
            $('#csTidalId').value = config.TidalClientId || '';
            $('#csTidalSecret').value = config.TidalClientSecret || '';
            $('#csTidalCountry').value = config.TidalCountryCode || 'US';
            $('#csTidalSize').value = String(config.TidalArtSize || 1080);
            $('#csTidalDelivery').value = config.TidalArtDelivery || 'cache';
        }).catch(function () {
            setStatus($('#csSaveMsg'), "Couldn't load the settings.", 'bad');
        });
    }

    $('#csSettingsForm').addEventListener('submit', function (e) {
        e.preventDefault();
        var btn = $('#csSave');
        var msg = $('#csSaveMsg');
        btn.disabled = true;
        setStatus(msg, 'Saving\u2026');
        // Read fresh, so a field this page does not show is kept as it is.
        ApiClient.getPluginConfiguration(PLUGIN_ID).then(function (config) {
            config.DisableSidecarWrites = $('#csDisableSidecarWrites').checked;
            config.SpicyLyricsSecretKey = $('#csSpicyKey').value.trim();
            // Administrators are implied, so only the users actually picked are saved.
            function picked(cls) {
                return Array.prototype.slice.call(page.querySelectorAll('.' + cls))
                    .filter(function (el) { return el.checked && !el.disabled; })
                    .map(function (el) { return el.getAttribute('data-id'); });
            }
            config.ServerWideSpotifyLinkUsers = picked('csLinkUser');
            config.ExplicitEditUsers = picked('csExplicitUser');
            config.ExplicitLookupDeezer = $('#csExplicitDeezer').checked;
            config.ExplicitLookupItunes = $('#csExplicitItunes').checked;
            config.MirrorExplicitTag = $('#csMirrorExplicitTag').checked;
            config.AnimatedArtEditUsers = picked('csArtUser');
            config.AnimatedArtSourceOrder = $('#csArtOrder').value;
            config.AnimatedArtSidecarNames = $('#csArtNames').value.split(',')
                .map(function (n) { return n.trim(); }).filter(function (n) { return n; });
            config.AnimatedArtMaxUploadMb = Math.max(1, parseInt($('#csArtMaxMb').value, 10) || 50);
            config.TidalClientId = $('#csTidalId').value.trim();
            config.TidalClientSecret = $('#csTidalSecret').value.trim();
            config.TidalCountryCode = ($('#csTidalCountry').value.trim() || 'US').toUpperCase();
            config.TidalArtSize = parseInt($('#csTidalSize').value, 10) || 1080;
            config.TidalArtDelivery = $('#csTidalDelivery').value;
            return ApiClient.updatePluginConfiguration(PLUGIN_ID, config);
        }).then(function () {
            setStatus(msg, 'Saved', 'ok');
        }, function () {
            setStatus(msg, "Couldn't save. Try again.", 'bad');
        }).then(function () { btn.disabled = false; });
        return false;
    });

    $('#csTidalTest').addEventListener('click', function () {
        var msg = $('#csTidalTestMsg');
        setStatus(msg, 'Testing\u2026');
        ApiClient.ajax({ type: 'POST', url: ApiClient.getUrl('CascadeServer/AnimatedArt/TidalTest'), dataType: 'json' })
            .then(function (r) { setStatus(msg, r.ok ? 'Works.' : r.error, r.ok ? 'ok' : 'bad'); })
            .catch(function () { setStatus(msg, 'The test could not run.', 'bad'); });
    });

    // -- Server style ----------------------------------------------------
    function stylePreview(text) {
        var el = $('#csStylePreview');
        var p;
        try { p = JSON.parse(text); } catch (e) { el.textContent = text.trim() ? 'Not valid JSON yet.' : ''; return; }
        if (!p || typeof p !== 'object') { el.textContent = 'Not a preset.'; return; }
        var parts = [];
        if (p.theme && typeof p.theme === 'object') parts.push('theme');
        if (p.lyrics && typeof p.lyrics === 'object') parts.push('lyrics');
        var t = p.theme || {};
        var hex = /^#[0-9a-fA-F]{6}$/;
        var swatch = hex.test(t.gradStart) && hex.test(t.gradEnd)
            ? '<span class="cs-swatch" style="background:linear-gradient(90deg,' + t.gradStart + ',' + t.gradEnd + ')"></span>' : '';
        el.innerHTML = swatch + '<span><strong>' + escapeHtml(p.name || 'Untitled') + '</strong>: ' +
            (parts.join(' and ') || 'nothing usable') + '</span>';
    }

    function loadStyle() {
        return ApiClient.getJSON(ApiClient.getUrl('CascadeServer/Style')).then(function (s) {
            $('#csStyleMode').value = s.mode;
            $('#csStyleEnforceTheme').checked = !!(s.enforce && s.enforce.theme);
            $('#csStyleEnforceLyrics').checked = !!(s.enforce && s.enforce.lyrics);
            $('#csStylePreset').value = s.preset ? JSON.stringify(s.preset, null, 2) : '';
            stylePreview($('#csStylePreset').value);
        }).catch(function () { setStatus($('#csStyleMsg'), "Couldn't load the server style.", 'bad'); });
    }

    $('#csStylePreset').addEventListener('input', function () { stylePreview(this.value); });
    $('#csStyleFile').addEventListener('change', function () {
        var f = this.files && this.files[0];
        this.value = '';
        if (!f) return;
        if (f.size > 65536) { setStatus($('#csStyleMsg'), 'That file is too large to be a Cascade preset.', 'bad'); return; }
        var r = new FileReader();
        r.onload = function () {
            var ta = $('#csStylePreset');
            ta.value = String(r.result);
            stylePreview(ta.value);
        };
        r.readAsText(f);
    });
    $('#csStyleForm').addEventListener('submit', function (e) {
        e.preventDefault();
        var msg = $('#csStyleMsg');
        var mode = $('#csStyleMode').value;
        var body = { mode: mode, enforce: { theme: $('#csStyleEnforceTheme').checked, lyrics: $('#csStyleEnforceLyrics').checked }, preset: null };
        if (mode !== 'off') {
            try { body.preset = JSON.parse($('#csStylePreset').value); } catch (err) { setStatus(msg, 'The preset is not valid JSON.', 'bad'); return false; }
        }
        ApiClient.ajax({ type: 'PUT', url: ApiClient.getUrl('CascadeServer/Style'), contentType: 'application/json', data: JSON.stringify(body) })
            .then(function () { setStatus(msg, 'Saved', 'ok'); loadStyle(); })
            .catch(function (res) { errorText(res, "Couldn't save the style.").then(function (m) { setStatus(msg, m, 'bad'); }); });
        return false;
    });
    $('#csStyleClear').addEventListener('click', function () {
        var msg = $('#csStyleMsg');
        ApiClient.ajax({ type: 'DELETE', url: ApiClient.getUrl('CascadeServer/Style') })
            .then(function () { setStatus(msg, 'Cleared', 'ok'); loadStyle(); })
            .catch(function (res) { errorText(res, "Couldn't clear the style.").then(function (m) { setStatus(msg, m, 'bad'); }); });
    });

    // -- Announcements (posts live in the plugin configuration) ------
    // Each change re-reads the configuration first, as the settings Save does,
    // so neither overwrites the other.
    function localDay(d) {
        function two(n) { return (n < 10 ? '0' : '') + n; }
        return d.getFullYear() + '-' + two(d.getMonth() + 1) + '-' + two(d.getDate());
    }
    function editAnnouncements(change) {
        return ApiClient.getPluginConfiguration(PLUGIN_ID).then(function (config) {
            config.Announcements = change(config.Announcements || []);
            return ApiClient.updatePluginConfiguration(PLUGIN_ID, config);
        });
    }
    function loadAnnouncements() {
        return ApiClient.getPluginConfiguration(PLUGIN_ID).then(function (config) {
            var list = (config.Announcements || []).slice().reverse();
            $('#csAnnList').innerHTML = list.length ? list.map(function (a) {
                return '<div class="cs-row"><span class="cs-label"><span class="cs-name">' + escapeHtml(a.Title) + '</span>' +
                    '<span class="cs-desc">' + escapeHtml(a.Date) + (a.Body ? ' \u00b7 ' + escapeHtml(a.Body.slice(0, 140)) : '') + '</span></span>' +
                    '<button type="button" class="cs-btn cs-danger cs-small" data-ann="' + escapeHtml(a.Id) + '">Delete</button></div>';
            }).join('') : '<div class="cs-empty">Nothing posted.</div>';
        }).catch(function () { setStatus($('#csAnnMsg'), "Couldn't load the announcements.", 'bad'); });
    }
    $('#csAnnForm').addEventListener('submit', function (e) {
        e.preventDefault();
        var msg = $('#csAnnMsg');
        var post = {
            Id: Date.now().toString(36) + Math.random().toString(36).slice(2, 6),
            // The admin's own day, as the apps date a kept dashboard message:
            // toISOString's UTC day ran a day ahead in the evening.
            Date: localDay(new Date()),
            Title: $('#csAnnTitle').value.trim(),
            Body: $('#csAnnBody').value.trim(),
            Link: $('#csAnnLink').value.trim(),
        };
        if (!post.Title) return false;
        editAnnouncements(function (list) { return list.concat([post]); }).then(function () {
            $('#csAnnTitle').value = $('#csAnnBody').value = $('#csAnnLink').value = '';
            setStatus(msg, 'Posted', 'ok');
            loadAnnouncements();
        }, function () { setStatus(msg, "Couldn't post it.", 'bad'); });
        return false;
    });
    $('#csAnnList').addEventListener('click', function (e) {
        var btn = e.target.closest('[data-ann]');
        if (!btn || !confirm('Delete this announcement? It disappears from everyone\'s inbox.')) return;
        var id = btn.getAttribute('data-ann');
        editAnnouncements(function (list) { return list.filter(function (a) { return a.Id !== id; }); })
            .then(function () { setStatus($('#csAnnMsg'), 'Deleted', 'ok'); loadAnnouncements(); },
                function () { setStatus($('#csAnnMsg'), "Couldn't delete it.", 'bad'); });
    });

    // -- Lyrics coverage -------------------------------------------------
    var allRows = [];

    function statusBadge(row) {
        if (!row.checkedAtAll) return '<span class="cs-badge">Not checked</span>';
        return row.kugouAvailable ? '<span class="cs-badge ok">Available</span>' : '<span class="cs-badge bad">Missing</span>';
    }
    function storedLabel(row) {
        var parts = [];
        if (row.hasKaraoke) parts.push('.slrc');
        if (row.hasSynced) parts.push('.lrc');
        if (row.hasPlain) parts.push('.txt');
        if (!parts.length) return '-';
        return parts.join(' \u00b7 ') + (row.cached ? ' (data folder)' : '');
    }

    function render() {
        var missingOnly = $('#clMissingOnly').checked;
        var filter = $('#clFilter').value.trim().toLowerCase();
        var checked = allRows.filter(function (r) { return r.checkedAtAll; });
        var available = checked.filter(function (r) { return r.kugouAvailable; }).length;
        $('#clAvailable').textContent = available.toLocaleString();
        $('#clMissing').textContent = (checked.length - available).toLocaleString();
        $('#clUnchecked').textContent = (allRows.length - checked.length).toLocaleString();
        $('#clBar').style.width = checked.length ? (100 * available / checked.length) + '%' : '0';
        $('#clSummary').textContent = checked.length
            ? Math.round(100 * available / checked.length) + '% of checked tracks have them.' : '';

        var tbody = $('#clRows');
        tbody.innerHTML = '';
        allRows.filter(function (r) {
            if (missingOnly && (!r.checkedAtAll || r.kugouAvailable)) return false;
            return !filter || (r.name + ' ' + r.artist).toLowerCase().indexOf(filter) !== -1;
        }).forEach(function (r) {
            var tr = document.createElement('tr');
            tr.innerHTML = '<td>' + escapeHtml(r.name) + '</td><td>' + escapeHtml(r.artist) + '</td><td>' + statusBadge(r) + '</td>' +
                '<td>' + storedLabel(r) + '</td><td>' + (r.lastChecked ? new Date(r.lastChecked).toLocaleString() : '-') + '</td><td></td>';
            var btn = document.createElement('button');
            btn.type = 'button';
            btn.className = 'cs-btn cs-secondary cs-small';
            btn.textContent = 'Recheck';
            btn.addEventListener('click', function () { recheck(r.itemId, btn); });
            tr.lastElementChild.appendChild(btn);
            tbody.appendChild(tr);
        });
    }

    function load(silent) {
        if (!silent) $('#clSummary').textContent = 'Loading\u2026';
        return ApiClient.getJSON(ApiClient.getUrl('CascadeServer/Status')).then(function (data) {
            allRows = data || [];
            render();
        }).catch(function () {
            if (!silent) $('#clSummary').textContent = "Couldn't load the coverage.";
        });
    }

    function recheck(itemId, btn) {
        btn.disabled = true;
        btn.textContent = 'Checking\u2026';
        ApiClient.ajax({ type: 'POST', url: ApiClient.getUrl('CascadeServer/Status/' + itemId + '/Recheck'), dataType: 'json' })
            .then(function (updated) {
                var idx = allRows.findIndex(function (r) { return r.itemId === itemId; });
                if (idx !== -1) allRows[idx] = updated;
                render();
            })
            .catch(function () { btn.disabled = false; btn.textContent = 'Retry'; });
    }

    // "Check all" runs Jellyfin's own Download lyrics scheduled task rather
    // than a bespoke bulk endpoint, so its progress comes from the core
    // ScheduledTasks API.
    var CASCADE_TASK_KEY = 'CascadeLyricsDownload';
    var checkAllTimer = null;

    function stopCheckAllPolling() {
        if (checkAllTimer) { clearInterval(checkAllTimer); checkAllTimer = null; }
    }
    function resetCheckAll(btn) { btn.disabled = false; btn.textContent = 'Check all'; }

    function pollCheckAll(taskId, btn) {
        stopCheckAllPolling();
        checkAllTimer = setInterval(function () {
            ApiClient.getJSON(ApiClient.getUrl('ScheduledTasks/' + taskId)).then(function (task) {
                if (task.State === 'Running' || task.State === 'Cancelling') {
                    var pct = task.CurrentProgressPercentage;
                    btn.textContent = 'Checking\u2026 ' + (pct != null ? Math.round(pct) + '%' : '');
                    load(true);
                } else {
                    stopCheckAllPolling();
                    resetCheckAll(btn);
                    load();
                }
            }).catch(function () { stopCheckAllPolling(); resetCheckAll(btn); });
        }, 3000);
    }

    $('#clCheckAllBtn').addEventListener('click', function () {
        var btn = this;
        btn.disabled = true;
        btn.textContent = 'Starting\u2026';
        ApiClient.getJSON(ApiClient.getUrl('ScheduledTasks')).then(function (tasks) {
            var task = tasks.find(function (t) { return t.Key === CASCADE_TASK_KEY; });
            if (!task) throw new Error('task not found');
            return ApiClient.ajax({ type: 'POST', url: ApiClient.getUrl('ScheduledTasks/Running/' + task.Id) })
                .then(function () { pollCheckAll(task.Id, btn); });
        }).catch(function () { resetCheckAll(btn); });
    });
    $('#clRefreshBtn').addEventListener('click', function () { load(); });
    $('#clMissingOnly').addEventListener('change', render);
    $('#clFilter').addEventListener('input', render);

    // -- Showing the page ------------------------------------------------
    function loadInfo() {
        return ApiClient.getJSON(ApiClient.getUrl('CascadeServer/Info')).then(function (i) {
            if (i && i.version) $('#csVersion').textContent = 'Version ' + String(i.version).split('.').slice(0, 3).join('.');
        }).catch(function () {});
    }

    var lastRefresh = 0;
    function refresh() {
        // This script can arrive after the first viewshow, so it loads on its
        // own too; the two together within a second load once.
        if (Date.now() - lastRefresh < 1000) return;
        lastRefresh = Date.now();
        loadSettings();
        loadStyle();
        loadAnnouncements();
        loadInfo();
        load();
        requestAnimationFrame(placePill);
    }
    page.addEventListener('viewshow', refresh);
    page.addEventListener('viewdestroy', stopCheckAllPolling);
    refresh();
})();
