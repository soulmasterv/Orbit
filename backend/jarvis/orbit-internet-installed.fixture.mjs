// Run explicitly with the installed tracker module URL; all state is temporary.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import crypto from 'node:crypto';
import assert from 'node:assert/strict';
import {OrbitInternetTracker} from './orbit-internet-tracker.mjs';
const {InternetRequests,landline,carrierOf} = await import(process.argv[2]);
const root=fs.mkdtempSync(path.join(os.tmpdir(),'orbit-installed-fixture-'));
const owner='201000000001',guest='201000000002';
try {
 const requests=new InternetRequests(root,[owner]);
 const tracker=new OrbitInternetTracker({requests,normalizeLine:landline,normalizeCarrier:carrierOf});
 assert.equal(tracker.root,root);
 const state=requests.read();state.friendsEnabled=true;state.invites={[guest]:true};requests.save(state);
 const change=(action,body={})=>tracker.mutate(guest,{request_id:crypto.randomUUID(),action,revision:tracker.view(guest).revision,...body});
 change('line',{slot:1,number:'0223456789',provider:'vodafone'});
 change('line',{slot:2,number:'0334567890',provider:'we'});
 assert.equal(tracker.view(guest).history.length,0);
 assert.equal(tracker.view(guest).lines[1].provider,'we');
 change('schedule',{slot:2,enabled:true,channel:'sms',policy:requests.policy(),confirmed:true});
 const scheduled=tracker.view(guest).lines[1];
 assert.equal(scheduled.weekly,true);assert.equal(scheduled.channel,'sms');
 assert.ok(Math.abs(scheduled.nextAt-Date.now())<10000);
 assert.equal(tracker.view(guest).history.length,0);
 change('schedule',{slot:2,enabled:false});
 assert.equal(tracker.view(guest).lines[1].weekly,false);
 const result=change('check',{slot:1,channel:'whatsapp',policy:requests.policy(),confirmed:true});
 assert.equal(result.operation,'queued');assert.equal(result.history[0].channel,'whatsapp');
 assert.equal(result.history[0].provider,'vodafone');
 assert.throws(()=>change('check',{slot:2,channel:'sms',policy:requests.policy(),confirmed:true}));
 assert.equal(tracker.view(guest).history.length,1);
 console.log('Installed tracker compatibility passed: two providers/slots, weekly today, read-only settings/history, channel and pending guard. Isolated jobs only; no worker or delivery invoked.');
} finally {fs.rmSync(root,{recursive:true,force:true});}
