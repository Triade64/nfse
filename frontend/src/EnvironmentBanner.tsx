import React from 'react';
import {ShieldAlert, ShieldCheck} from 'lucide-react';

type Company={id:number;name:string;config:Record<string,any>};

// 0.13.0: states the real emission environment of the registered companies (production = legally valid notes).
export function EnvironmentBanner({companies}:{companies:Company[]}){
 const production=companies.filter(c=>c.config?.ambiente==='1');
 if(!companies.length)return null;
 if(!production.length)return <div className="envBanner test" role="note"><ShieldCheck size={20}/><div><strong>Todas as empresas em produção restrita (testes)</strong><span>As notas emitidas não têm validade jurídica. O ambiente é escolhido por empresa, em Empresas → Editar.</span></div><span className="pill">TESTES</span></div>;
 const names=production.map(c=>c.name);
 const shown=names.slice(0,3).join(', ')+(names.length>3?` e mais ${names.length-3}`:'');
 return <div className="envBanner prod" role="note"><ShieldAlert size={20}/><div><strong>Produção ativa: notas reais, com validade jurídica</strong><span>{production.length===companies.length?'Todas as empresas emitem em produção':`Em produção: ${shown}`}. Cada emissão exige confirmação de nota real.</span></div><span className="pill">PRODUÇÃO</span></div>;
}
