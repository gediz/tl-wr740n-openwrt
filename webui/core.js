// SPDX-License-Identifier: MIT
// benchweb page logic, shared by all variants. Same endpoints, methods and fields as the old page:
// forms keep their action/method/names, JS only turns the submit into fetch() and shows the reply inline.
const $=i=>document.getElementById(i);
if(top!=self){document.body.innerHTML='';throw 0}
const esc=s=>String(s).replace(/[&<>"]/g,c=>'&#'+c.charCodeAt(0)+';');
const dur=s=>{s=Math.max(0,s|0);const d=s/86400|0,h=s/3600%24|0,m=s/60%60|0;return d?`${d}d ${h}h ${m}m`:h?`${h}h ${m}m`:m?`${m}m ${s%60}s`:s+'s'};
const mb=k=>(k/1024).toFixed(1)+' MB',tm=t=>new Date(t).toLocaleTimeString(),un=(v,u)=>v==null?'-':v+u;
// req: {s: HTTP status (0 = no answer), t: body, j: JSON or null, e: error text or ''}
const req=(m,u,b,h,to)=>fetch(u,{method:m,body:b||undefined,headers:h||undefined,cache:'no-store',signal:to?AbortSignal.timeout(to):undefined})
.then(r=>r.text().then(t=>{let j=null;try{j=JSON.parse(t)}catch(x){}return{s:r.status,t,j,e:r.ok?'':j&&j.error||r.statusText||'failed'}}),
x=>({s:0,t:String(x),j:null,e:'no answer from the router'}));
// the nearest .out next to (or above) an element
const out=e=>{for(;e;e=e.parentElement){const o=e.querySelector(':scope>.out');if(o)return o}};
const show=(o,c,h,raw)=>{const op=o.querySelector('details[open]');o.innerHTML=`<div class="msg ${c}">${h}</div>`+(raw?`<details class="raw"${op?' open':''}><summary>raw</summary><pre>${esc(raw)}</pre></details>`:'')};
const PROF={off:'radio off',open:'no encryption',wpa2:'WPA2-PSK',wpa3:'WPA3-SAE, PMF required',mixed:'WPA2-PSK and WPA3-SAE, PMF optional','ft-psk':'WPA2-PSK with 802.11r','ft-sae':'WPA3-SAE with 802.11r',owe:'OWE (Enhanced Open)'};
const tbl=(hd,rs)=>`<table><tr>${hd.map(x=>`<th>${x}</th>`).join('')}</tr>${rs.map(r=>`<tr>${r.map(x=>`<td>${esc(x)}</td>`).join('')}</tr>`).join('')}</table>`;
const nt=n=>['lan','wan','wlan'].map(i=>`<div class="nr"><span class="k">${i}</span>${(n[i]||[]).map(x=>`<span class="v${x.netem?' on':''}">${esc(x.dev)} ${esc(x.netem||'none')}</span>`).join('')||'<span class="v">no device</span>'}</div>`).join('');
// reply formatters, by data-fmt
const F={
wifi:j=>j.profile=='off'?'Wi-Fi radio is off.':`Applied <b>${esc(j.profile)}</b>, channel ${esc(j.channel)}. Wi-Fi reloads, clients reconnect in a few seconds.`,
netem:nt,
port:j=>`Port ${j.port} ${j.action=='up'?'powered up, autonegotiating':'powered down'} (BMCR ${esc(j.bmcr)}).`,
dhcp:j=>`DHCP server is now <b>${esc(j.dhcp)}</b>.`,
log:j=>`<pre class="log">${j.map(l=>`<span class="${/benchweb/.test(l)?'bw':/\.(err|crit|alert|emerg) /.test(l)?'e':/\.warn /.test(l)?'w':''}">${esc(l)}</span>`).join('\n')}</pre>`,
leases:j=>j.length?tbl(['Host','IP','MAC','Expires'],j.map(x=>[x.hostname||'-',x.ip,x.mac,x.expiry?new Date(x.expiry*1e3).toLocaleString():'never'])):'No leases.',
clients:j=>Object.keys(j).map(i=>`<b>${esc(i)}</b>`+(j[i].length?tbl(['MAC','Signal','RX','TX','Connected'],j[i].map(x=>[x.mac,un(x.signal_dbm,' dBm'),un(x.rx_mbit,' Mbit/s'),un(x.tx_mbit,' Mbit/s'),dur(x.connected_s)])):': no stations')).join('<br>')||'No AP is up.',
ping:j=>`<span class="${j.received?j.loss_pct?'w':'g':'e'}">${esc(j.host)}: ${j.received}/${j.transmitted} received, ${j.loss_pct}% loss</span>`+(j.rtt_ms?`, rtt min/avg/max ${j.rtt_ms.min}/${j.rtt_ms.avg}/${j.rtt_ms.max} ms`:''),
up:j=>{$('sh').value=j.sha256;return`Image passed the check, ${j.size.toLocaleString()} bytes.<br>sha256 <code>${esc(j.sha256)}</code><br>Compare it with sha256sums. The image stays in RAM until ${tm(Date.now()+j.keep_s*1e3)}, then it is deleted.`},
flash:j=>`Flashing, settings ${j.keep_settings?'kept':'reset'}. Do not power off.`,
restore:()=>'Backup restored, rebooting.',
reboot:()=>'Rebooting.',
reset:()=>'Factory reset, rebooting. The web password changes: read the new one over SSH.'};
// after a successful reply
const AF={wifi:()=>setTimeout(status,4e3),netem:status,port:()=>setTimeout(status,3e3),dhcp:status,flash:back,restore:back,reboot:back,reset:back};
function run(o,m,u,b,hd,k,btn){
show(o,'busy',`${m} ${esc(u)}`);if(btn)btn.disabled=1;
return req(m,u,b,hd).then(r=>{if(btn)btn.disabled=0;
const raw=`${m} ${u}${b?'\n'+(b instanceof Blob?`[${b.name}, ${b.size} bytes]`:b):''}\n\nHTTP ${r.s}\n${r.t}`;
if(r.e)return show(o,'err',(r.s?`HTTP ${r.s}: `:'')+esc(r.e),raw);
const h=(F[k]||(j=>esc(JSON.stringify(j))))(r.j);show(o,'ok',h,raw);AF[k]&&AF[k](o,h)})}
document.addEventListener('submit',e=>{e.preventDefault();
const f=e.target,b=e.submitter,k=b?.dataset.fmt||f.dataset.fmt,p=new URLSearchParams(new FormData(f,b));
let c=f.dataset.confirm,u=b?.getAttribute('formaction')||f.getAttribute('action');
if(!b?.formNoValidate&&!f.reportValidity())return;
if(k=='port'&&b.value=='down')c=`Power down port ${f.port.value}?`+(lk[f.port.value]?' It has a link now. If this computer is on it, the page stops answering until the port is brought up another way or the router reboots.':'');
if(k=='netem'&&b?.value=='set'&&f.iface.value!='wan'&&!f.for_s.value&&(f.loss_pct.value>=50||f.delay_ms.value>=2e3))c=`No auto-clear set. This much delay or loss on ${f.iface.value} can cut this page off. Continue?`;
if(c&&!confirm(c))return;
if(f.method=='get'){if(p.size)u+='?'+p;run(out(f),'GET',u,0,0,k,b)}else run(out(f),'POST',u,p,0,k,b)});
document.addEventListener('click',e=>{const b=e.target.closest('[data-up]');if(!b)return;
const f=$(b.dataset.file).files[0],o=out(b);if(!f)return show(o,'err','Choose a file first.');
if(b.dataset.confirm&&!confirm(b.dataset.confirm))return;
run(o,'POST',b.dataset.up,f,{'Content-Type':'application/octet-stream'},b.dataset.fmt,b)});
// status
let lk={},st=0,u0=0,ti;
function paint(s,t){u0=s.uptime;
$('s-uptime').textContent=dur(s.uptime);$('s-load').textContent=s.load.map(x=>x.toFixed(2)).join(' ');
const T=s.mem_kb.total,A=s.mem_kb.available,p=Math.round((T-A)*100/T),bar=$('s-membar');
$('s-memp').textContent=p+'%';$('s-mem').textContent=`${mb(T-A)} used of ${mb(T)}, ${mb(A)} available`;
bar.style.width=p+'%';bar.dataset.l=p>85?'hi':p>70?'mid':'';
$('s-fw').textContent=s.firmware;$('s-kernel').textContent=s.kernel;$('s-ip').textContent=s.lan_ip;
$('s-ports').innerHTML=[1,2,3,4].map(n=>{const v=s.ports?.[n]||'',up=lk[n]=/link:up/.test(v),sp=v.match(/speed:(\d+)/)?.[1];
return $('pc'+n).innerHTML=`<span class="chip${up?' up':''}" title="${esc(v||'no switch')}"><b>${n}</b> ${up?(sp?sp+'M':'up')+(/full/.test(v)?' FD':/half/.test(v)?' HD':''):s.ports?'down':'n/a'}</span>`}).join(' ');
const w=s.wifi;$('s-wifi').innerHTML=`<span class="chip${w.up?' up':''}">${w.up?'up':'down'}</span>`+[['profile',w.profile],['ssid',w.ssid],['channel',w.channel],['security',w.encryption],['clients',w.clients],['iface',w.ifname]].filter(x=>x[1]!=null).map(x=>`<span class="kv"><em>${x[0]}</em> ${esc(x[1])}</span>`).join(' ');
if(!wp.dataset.t&&PROF[w.profile]){wp.value=w.profile;hint()}
$('s-netem').innerHTML=nt(s.netem);if(t)$('s-raw').textContent=t;$('s-upd').textContent='updated '+tm(Date.now())}
// one request at a time; a refresh asked for meanwhile runs when it ends
function status(){if(st){st=2;return}st=1;
req('GET','/cgi-bin/status',0,0,8e3).then(r=>{const q=st>1;st=0;document.body.classList.toggle('stale',!!r.e);r.e?$('s-upd').textContent='status: '+r.e:paint(r.j,r.t);q&&status()})}
// after reboot, flash, restore or reset: poll status until the router answers with a new uptime
function back(o,h){const t0=Date.now(),u=u0;let gone=0;show(o,'busy',h+' Waiting for the router.');
const tick=()=>{const s=(Date.now()-t0)/1e3|0;
if(s>480)return show(o,'err',h+` No answer after ${s} s. Check the router (serial or TFTP recovery).`);
req('GET','/cgi-bin/status',0,0,4e3).then(r=>{
if(r.s==200&&(gone||r.j.uptime<u)){show(o,'ok',h+` Back after ${s} s.`);paint(r.j,r.t)}
else if(r.s==401)show(o,'ok',h+` Back after ${s} s, asking for the new password.`);
else{gone=gone||!r.s;show(o,'busy',h+` Waiting for the router: ${s} s.`);setTimeout(tick,3e3)}})};setTimeout(tick,4e3)}
$('pc').innerHTML=[1,2,3,4].map(n=>`<form method="post" action="/cgi-bin/port" data-fmt="port"><input type="hidden" name="port" value="${n}"><span id="pc${n}"><span class="chip"><b>${n}</b></span></span><button name="action" value="up">Up</button><button name="action" value="down" class="alt">Down</button></form>`).join('');
const wp=$('wp'),hint=()=>$('wpd').textContent=PROF[wp.value];wp.onchange=()=>{wp.dataset.t=1;hint()};hint();
const auto=()=>{clearInterval(ti);if($('ar').checked)ti=setInterval(()=>document.hidden||status(),$('ari').value*1e3)};
$('ar').onchange=$('ari').onchange=auto;$('rf').onclick=status;status();
