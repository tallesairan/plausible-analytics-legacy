!function(){"use strict";var r=window.location,o=window.document,e=window.localStorage,p=o.currentScript,l=p.getAttribute("data-api")||new URL(p.src).origin+"/api/event",s=e&&e.plausible_ignore,w=p&&p.getAttribute("data-exclude").split(",");function d(e){console.warn("Ignoring Event: "+e)}function t(e,t){if(!(window._phantom||window.__nightmare||window.navigator.webdriver||window.Cypress)){if("true"==s)return d("localStorage flag");if(w)for(var i=0;i<w.length;i++)if("pageview"==e&&r.pathname.match(new RegExp("^"+w[i].trim().replace(/\*\*/g,".*").replace(/([^\.])\*/g,"$1[^\\s/]*")+"/?$")))return d("exclusion rule");var n={};n.n=e,n.u=r.href,n.d=p.getAttribute("data-domain"),n.r=o.referrer||null,n.w=window.innerWidth,t&&t.meta&&(n.m=JSON.stringify(t.meta)),t&&t.props&&(n.p=JSON.stringify(t.props));var a=new XMLHttpRequest;a.open("POST",l,!0),a.setRequestHeader("Content-Type","text/plain"),a.send(JSON.stringify(n)),a.onreadystatechange=function(){4==a.readyState&&t&&t.callback&&t.callback()}}}var i=window.plausible&&window.plausible.q||[];window.plausible=t;for(var n,a=0;a<i.length;a++)t.apply(this,i[a]);function u(){n!==r.pathname&&(n=r.pathname,t("pageview"))}var c,g=window.history;g.pushState&&(c=g.pushState,g.pushState=function(){c.apply(this,arguments),u()},window.addEventListener("popstate",u)),"prerender"===o.visibilityState?o.addEventListener("visibilitychange",function(){n||"visible"!==o.visibilityState||u()}):u()}();