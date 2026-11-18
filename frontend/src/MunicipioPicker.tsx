import React, {useEffect, useRef, useState} from 'react';

type Api=(path:string,method?:string,data?:any)=>Promise<any>;
type Municipio={codigo:string;nome:string;uf:string};

// 0.14.0: municipality chosen by name (official IBGE table); the 7-digit code is filled in for the person.
export function MunicipioPicker({api,label,value,onChange,required=false}:{api:Api;label:string;value:string;onChange:(codigo:string,nome:string)=>void;required?:boolean}){
 const [text,setText]=useState(''),[options,setOptions]=useState<Municipio[]>([]),[open,setOpen]=useState(false);
 const timer=useRef<number|undefined>(undefined);
 useEffect(()=>{if(/^\d{7}$/.test(value||'')){api('/municipios?codigo='+value).then((r:Municipio[])=>{if(r[0])setText(`${r[0].nome} / ${r[0].uf}`)}).catch(()=>{})}},[value]);
 function search(term:string){setText(term);if(value)onChange('','');window.clearTimeout(timer.current);if(term.trim().length<2){setOptions([]);return}
  timer.current=window.setTimeout(()=>{api('/municipios?q='+encodeURIComponent(term.trim())).then((r:Municipio[])=>{setOptions(r);setOpen(true)}).catch(()=>setOptions([]))},250)}
 function pick(m:Municipio){onChange(m.codigo,m.nome);setText(`${m.nome} / ${m.uf}`);setOpen(false)}
 return <label className="municipioPicker">{label}
  <input value={text} required={required} placeholder="Digite o nome da cidade" autoComplete="off" onChange={e=>search(e.target.value)} onFocus={()=>options.length&&setOpen(true)} onBlur={()=>window.setTimeout(()=>setOpen(false),150)} aria-invalid={required&&!value&&text.length>0} aria-autocomplete="list"/>
  {value?<small>Código IBGE {value}</small>:text.length>=2&&!open&&<small className="rowError">Escolha a cidade na lista.</small>}
  {open&&options.length>0&&<ul role="listbox" className="pickerList">{options.map(m=><li key={m.codigo} role="option" aria-selected={m.codigo===value} onMouseDown={e=>{e.preventDefault();pick(m)}}>{m.nome} / {m.uf}<small>{m.codigo}</small></li>)}</ul>}
 </label>;
}
