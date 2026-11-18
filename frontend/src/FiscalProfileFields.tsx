type Profile={op_simp_nac:string;reg_ap_trib_sn:string|null;reg_esp_trib:string;totals_mode:string;include_provider_im:boolean;include_iss_rate:boolean;series:string};

// Starting point the restricted API accepted for an ME/EPP in the Simples: omit IM (E0120), omit ISS rate (E0625),
// and inform the Simples percentage at each emission (E0712). Always reviewed per company.
const DEFAULT:Profile={op_simp_nac:'3',reg_ap_trib_sn:'1',reg_esp_trib:'0',totals_mode:'simples_percent',include_provider_im:false,include_iss_rate:false,series:'1'};

// 0.14.0: the tax regime chosen in plain words drives the technical profile (Simples situation and tax totals mode).
export const REGIMES=[
 {value:'Simples Nacional',label:'Simples Nacional (ME/EPP)',hint:'Informa o percentual do Simples a cada nota.',op:'3'},
 {value:'MEI',label:'MEI',hint:'Microempreendedor individual.',op:'2'},
 {value:'Lucro Presumido',label:'Lucro Presumido',hint:'Informa os percentuais federal, estadual e municipal (IBPT) a cada nota.',op:'1'},
 {value:'Lucro Real',label:'Lucro Real',hint:'Informa os percentuais federal, estadual e municipal (IBPT) a cada nota.',op:'1'},
] as const;
const TOTALS:Record<string,string>={'3':'simples_percent','1':'percentages','2':'not_informed'};
export function profileForRegime(op:string,current?:Profile|null):Profile{
 const base={...DEFAULT,...(current||{})};
 return {...base,op_simp_nac:op,reg_ap_trib_sn:op==='3'?base.reg_ap_trib_sn||'1':null,totals_mode:TOTALS[op]};
}

// Emission environment per company (0.10.0). Production issues legally valid notes; only an administrator changes it.
export function EnvironmentField({value,onChange,hasProfile}:{value:string|undefined;onChange:(v:string)=>void;hasProfile:boolean}){
 const production=value==='1';
 return <fieldset className="wide fiscalProfile"><legend>Ambiente de emissão</legend>
  <label>Ambiente<select aria-label="Ambiente de emissão" value={production?'1':'2'} onChange={e=>{const v=e.target.value;if(v==='1'&&!window.confirm('Colocar esta empresa em PRODUÇÃO?\n\nAs próximas notas emitidas terão VALIDADE JURÍDICA e serão enviadas à SEFIN Nacional de produção. Para corrigir uma nota real é preciso cancelar ou substituir no Emissor Nacional.'))return;onChange(v)}}><option value="2">Produção restrita (testes, sem validade jurídica)</option><option value="1" disabled={!hasProfile}>Produção (notas reais, com validade jurídica)</option></select></label>
  {production?<p className="danger">PRODUÇÃO: cada emissão gera uma NFS-e real. Configure a numeração de produção em Configurações → Numeração de DPS antes de emitir.</p>:<p className="muted">Notas emitidas em produção restrita não têm validade jurídica.{!hasProfile&&' Configure o perfil fiscal para poder escolher produção.'}</p>}
 </fieldset>;
}

export function FiscalProfileFields({value,onChange,hideRegime=false}:{value:(Profile&{simples_percent?:unknown})|undefined|null;onChange:(p:Profile|null)=>void;hideRegime?:boolean}){
 if(!value)return <fieldset className="wide fiscalProfile"><legend>Perfil fiscal para emissão</legend><p className="muted">Sem perfil, as notas desta empresa não podem ser emitidas. O perfil guarda as escolhas tributárias usadas em toda emissão.</p><button type="button" onClick={()=>onChange({...DEFAULT})}>Configurar perfil fiscal</button></fieldset>;
 const {simples_percent:_legacy,...current}=value;
 const set=(patch:Partial<Profile>)=>onChange({...current,...patch});
 return <fieldset className="wide fiscalProfile"><legend>Perfil fiscal para emissão</legend>
  <p className="muted">Usado em toda emissão desta empresa. Confira com a situação cadastral e as regras do município; alterar o perfil revalida as notas na próxima emissão.</p>
  <div className="formGrid">
   <label>Série da DPS<input required pattern="0{0,4}([1-9][0-9]{0,3}|[1-4][0-9]{4})" title="De 1 a 49999: faixa do aplicativo próprio (regra E0010)" maxLength={5} value={current.series} onChange={e=>set({series:e.target.value})}/><small>1 a 49999 (aplicativo próprio, regra E0010). Não use a série do Emissor Web (70000+).</small></label>
   {!hideRegime&&<label>Situação no Simples Nacional<select value={current.op_simp_nac} onChange={e=>onChange(profileForRegime(e.target.value,current))}><option value="1">Não optante (Lucro Presumido/Real)</option><option value="2">MEI</option><option value="3">ME/EPP optante pelo SN</option></select></label>}
   {current.op_simp_nac==='3'&&<label>Regime de apuração SN<select value={current.reg_ap_trib_sn||'1'} onChange={e=>set({reg_ap_trib_sn:e.target.value})}><option value="1">Federais e ISS no SN</option><option value="2">Federais no SN e ISS fora</option><option value="3">Federais e ISS fora do SN</option></select></label>}
   <label>Regime especial municipal<select value={current.reg_esp_trib} onChange={e=>set({reg_esp_trib:e.target.value})}><option value="0">Nenhum</option><option value="1">Cooperativa</option><option value="2">Estimativa</option><option value="3">Microempresa municipal</option><option value="4">Notário/registrador</option><option value="5">Profissional autônomo</option><option value="6">Sociedade de profissionais</option><option value="9">Outros</option></select></label>
   <label>Inscrição municipal no XML<select value={current.include_provider_im?'include':'omit'} onChange={e=>set({include_provider_im:e.target.value==='include'})}><option value="omit">Omitir (exigido quando o CNC não tem complemento — E0120)</option><option value="include">Incluir a IM cadastrada</option></select></label>
   <label>Alíquota de ISS no XML<select value={current.include_iss_rate?'include':'omit'} onChange={e=>set({include_iss_rate:e.target.value==='include'})}>{current.op_simp_nac==='1'?<><option value="omit">Omitir — município com convênio ativo na NFS-e Nacional (E0617), ex.: Garopaba</option><option value="include">Incluir — município sem convênio ativo (obrigatório, E0619)</option></>:<><option value="omit">Omitir (ME/EPP no SN sem retenção — E0625)</option><option value="include">Incluir a alíquota da nota</option></>}</select></label>
   <p className="wide muted">Tributos totais: {current.op_simp_nac==='3'?'percentual aproximado do Simples, informado a cada emissão (obrigatório para ME/EPP — E0712). O campo vem preenchido com o último percentual usado.':current.op_simp_nac==='1'?'percentuais aproximados federal, estadual e municipal (tabela IBPT), informados a cada emissão (obrigatórios para não optante — E0713).':'não informar estimativa (MEI).'}</p>
  </div>
  <button type="button" className="textBtn" onClick={()=>onChange(null)}>Remover perfil fiscal</button>
 </fieldset>;
}
