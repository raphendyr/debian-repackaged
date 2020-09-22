'use strict';

Object.defineProperty(exports, "__esModule", {
  value: true
});
exports.inject = inject;
exports.findAndInject = findAndInject;

const fs = require('fs');
const pathlib = require('path');
const electron = require('electron');

const HOME = process.env.HOME;
const CSS_FILES = [
  "/usr/share/discord-canary/resources/fix_styles.css",
  pathlib.join(HOME, ".config/discordcanary/user.css"),
]


var STATE = {};


function applyCSS(webContents, path, name) {
  console.log(" >>> applyCSS:", name);
  var data = undefined;
  try {
    data = fs.readFileSync(path, "utf-8");
  } catch (err) {
    if (err.code === 'ENOENT') {
      console.log(" >>> applyCSS: file missing, skipping update...");
    } else {
      throw err;
    }
  }
  if (data !== undefined && data !== null) {
    webContents.send('DISCORD_apply-CSS', {'name': name, 'data': data});
  }
}


function clearCSS(webContents, name) {
  console.log(" >>> clearCSS:", name);
  webContents.send('DISCORD_clear-CSS', {'name': name});
}


function teardownCSS(webContents) {
  webContents.send('DISCORD_teardown-CSS');
  let watchers = STATE[webContents];
  if (typeof watchers != 'undefined') {
    for (var path in watchers.length) {
      watchers[path].close();
    }
    delete STATE[webContents];
  }
}


function watchPath(webContents, path) {
  console.log(" - watchPath:", path);
  var files, dirname;
  if (!fs.existsSync(path)) {
    console.log(" \\- path missing, watcher not started")
    return;
  }
  if (fs.lstatSync(path).isDirectory()) {
    files = fs.readdirSync(path);
    dirname = path;
  } else {
    files = [pathlib.basename(path)];
    dirname = pathlib.dirname(path);
  }

  let watchers = STATE[webContents];
  if (typeof watchers == 'undefined') {
    STATE[webContents] = watchers = {};
  }

  let fileWatcher = watchers[path];
  if (typeof fileWatcher == 'undefined') {
    console.log(" \\- starting file update watcher for ", path);
    try {
      watchers[path] = fs.watch(dirname, { encoding: "utf-8" },
        function(eventType, file) {
          if (!file.endsWith(".css")) return;
          path = pathlib.join(dirname, file);
          if (eventType === "rename" || !fs.existsSync(path)) {
            clearCSS(webContents, file);
          } else {
            applyCSS(webContents, pathlib.join(dirname, file), file);
          }
        }
      );
    } catch (err) {
      console.log(" \\- We were unable to watch path: ", err)
    }
  }

  files.forEach(function(file) {
    if (file.endsWith('.css'))
      applyCSS(webContents, pathlib.join(dirname, file), file);
  });
}


function install(webContents) {
  console.log(" -- installing apply-CSS, clear-CSS and teardown-CSS...")
  return webContents
    .executeJavaScript('console.log(" << injectCss.js / install / executeJavaScript >> ")')
    .then(() => {
      return webContents.executeJavaScript(`
        if (typeof window._csslog == 'undefined') {
          window._csslog = function(section, message) {
            console.log("%c [fixCSS/%s] %c %s", "color: #4fe453; background: black; font-weight: bold;", section, "", message);
          };
        }
        if (typeof window._styleTag == 'undefined') {
          window._csslog("init", "adding hooks for *-CSS");
          window._styleTag = {};
          DiscordNative.ipc.on('apply-CSS', function(event, message) {
            let name = message['name'], data = message['data'];
            window._csslog("apply-CSS", \`name: \${name}\`);
            if (!window._styleTag.hasOwnProperty(name)) {
              window._styleTag[name] = document.createElement("style");
              document.head.appendChild(window._styleTag[name]);
            }
            window._styleTag[name].innerHTML = data;
          });
          window._clearCSS = function(name) {
            if (window._styleTag.hasOwnProperty(name)) {
              window._styleTag[name].innerHTML = "";
              window._styleTag[name].parentElement.removeChild(window._styleTag[name]);
              delete window._styleTag[name];
            }
          };
          DiscordNative.ipc.on('clear-CSS', function(event, message) {
            let name = message['name'];
            window._csslog("clear-CSS", \`name: \${name}\`);
            window._clearCSS(name);
          });
          DiscordNative.ipc.on('teardown-CSS', function(event, message) {
            window._csslog("teardown-CSS", "tearing down..");
            for (var key in window._styleTag)
              window._clearCSS(key);
          });
        } else {
          window._csslog("init", "window._styleTag already exists.");
        }
      `)
      .then(value => console.log(` -- installation OK: ${JSON.stringify(value)} `))
      .catch(err => console.log(` !! failed webContents.exercuteJavaScript: ${err.message}`))
    })
    .catch(err => console.log(` !! failed webContents.exercuteJavaScript: ${err.message}`))
}


function inject(webContents) {
  console.log(" -- injecting...");
  if (webContents.isLoading()) {
    console.log("  \\- waiting...");
    setTimeout(inject, 1000, webContents);
  } else {
    install(webContents).then(() => {
      teardownCSS(webContents);
      console.log(" -- adding some css files...")
      CSS_FILES.forEach(path => watchPath(webContents, path));
    })
  }
}

var findAndInjectAttempt = 0;
function findAndInject() {
  console.log(` -- injectCss.findAndInject(), attempt ${findAndInjectAttempt}`);

  // Find the main window by iterating over them
  let webContents = null;
  let wins = electron.BrowserWindow.getAllWindows();
  for (var i = 0; i < wins.length; i++) {
    let win = wins[i];
    console.log("  - win: " + win + ", url: " + (typeof win.webContents != 'undefined' ? win.webContents.getURL() : 'none'));
    if (typeof win.webContents != 'undefined' && win.webContents.getURL().indexOf("canary.discordapp.com/channels") > 0) {
      webContents = win.webContents;
      break;
    }
  };

  if (webContents != null) {
    // found, injection passed to next step
    inject(webContents);
  } else {
    // didn't find, try again
    findAndInjectAttempt++;
    setTimeout(findAndInject, 2000);
  }
}
