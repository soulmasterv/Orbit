const panel=document.getElementById('memory-panel'),list=document.getElementById('memory-list'),input=document.getElementById('memory-text'),notice=document.getElementById('memory-status');
let token=()=>null;
async function request(method,body){
  const r=await fetch('/memory',{method,headers:{'Content-Type':'application/json','X-CSRF-Token':token()},...(body?{body:JSON.stringify(body)}:{})});
  if(r.status===401){window.dispatchEvent(new Event('orbit-jarvis-auth-expired'));throw Error('Session expired. Sign in again.');}
  const data=await r.json();if(!r.ok)throw Error('Memory request failed. Check your connection or sign in again.');return data.items;
}
function render(items){
  list.replaceChildren();
  if(!items.length){const p=document.createElement('p');p.textContent='No saved memories yet.';list.append(p);}
  for(const item of items){
    const card=document.createElement('div'),field=document.createElement('textarea'),save=document.createElement('button'),remove=document.createElement('button');
    card.className='memory-card';field.value=item.text;field.maxLength=500;field.setAttribute('aria-label','Saved memory');
    save.textContent='Save edit';remove.textContent='Delete';save.type=remove.type='button';
    save.onclick=()=>void change('PUT',{id:item.id,text:field.value});remove.onclick=()=>{if(confirm('Delete this saved memory?'))void change('DELETE',{id:item.id});};
    card.append(field,save,remove);list.append(card);
  }
}
async function change(method,body){
  try{render(await request(method,body));input.value='';notice.textContent='Memory updated. Start a new voice session to use it.';window.dispatchEvent(new Event('orbit-jarvis-memory-changed'));}
  catch(e){notice.textContent=e.message;}
}
export function initMemory(getCsrf){token=getCsrf;
  document.getElementById('memory-form').onsubmit=e=>{e.preventDefault();void change('POST',{text:input.value});};
  document.getElementById('memory-refresh').onclick=()=>void showMemory(true);
  document.getElementById('memory-clear').onclick=()=>{if(confirm('Delete all saved memories? This cannot be undone.'))void change('DELETE',{all:true});};
}
export async function showMemory(visible){
  panel.hidden=!visible;
  if(!visible){list.replaceChildren();input.value='';notice.textContent='';return;}
  try{render(await request('GET'));}catch(e){notice.textContent=e.message;}
}
export function proposeMemory(text){
  input.value=text;notice.textContent='JARVIS drafted a memory. Review the text and click Save memory to keep it. Nothing is saved yet.';input.focus();
}
