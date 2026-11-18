// @vitest-environment jsdom
import React, {useState} from 'react';
import {render,screen,fireEvent,waitFor,cleanup,within} from '@testing-library/react';
import {afterEach,expect,it,vi} from 'vitest';
import {CompanyForm, companyProblems, companyPayload} from './CompanyForm';
import {CustomerForm, customerProblems, customerPayload} from './CustomerForm';
import {documentStatus, validCnpj, validCpf} from './documents';
import {Notas} from './Notas';
afterEach(()=>{cleanup();vi.restoreAllMocks()});

const api=vi.fn(async(path:string)=>path.startsWith('/municipios?q=')?[{codigo:'4205704',nome:'Garopaba',uf:'SC'}]:path.startsWith('/municipios?codigo=')?[{codigo:'4205704',nome:'Garopaba',uf:'SC'}]:[]);
function Harness({initial,kind}:{initial:any;kind:'company'|'customer'}){
 const [value,setValue]=useState(initial);
 return <><output data-testid="state">{JSON.stringify(value)}</output>{kind==='company'?<CompanyForm api={api} value={value} onChange={setValue} isAdmin/>:<CustomerForm api={api} value={value} onChange={setValue} companies={[{id:1,name:'ESCRITORIO'}]}/>}</>;
}
const state=()=>JSON.parse(screen.getByTestId('state').textContent||'{}');

it('validates CPF and CNPJ like the backend',()=>{
 expect(validCpf('52998224725')).toBe(true);expect(validCpf('52998224724')).toBe(false);
 expect(validCnpj('11222333000181')).toBe(true);expect(validCnpj('11222333000182')).toBe(false);
 expect(documentStatus('529.982.247-25')).toEqual({kind:'cpf',ok:true,message:'Pessoa física (CPF) válido.'});
 expect(documentStatus('1122233300018').message).toContain('13 dígitos');
});

it('company form: plain-language regime sets the technical profile and the city is picked by name',async()=>{
 render(<Harness kind="company" initial={{name:'',cnpj:'',config:{}}}/>);
 fireEvent.change(screen.getByLabelText(/^CNPJ/),{target:{value:'11222333000182'}});
 expect(screen.getByText('CNPJ inválido: confira os dígitos.')).toBeTruthy();
 fireEvent.change(screen.getByLabelText(/^CNPJ/),{target:{value:'11222333000181'}});
 fireEvent.change(screen.getByLabelText('Razão social'),{target:{value:'EMPRESA LP LTDA'}});
 expect(companyProblems(state())).toEqual(['cidade escolhida na lista','regime tributário']);
 fireEvent.change(screen.getByLabelText(/^Cidade/),{target:{value:'garop'}});
 fireEvent.mouseDown(await screen.findByRole('option',{name:/Garopaba \/ SC/}));
 expect(state().config).toMatchObject({municipio_ibge:'4205704',municipio:'Garopaba'});
 fireEvent.click(screen.getByRole('radio',{name:/Lucro Presumido/}));
 expect(state().config.regime).toBe('Lucro Presumido');
 expect(state().config.perfil_fiscal).toMatchObject({op_simp_nac:'1',reg_ap_trib_sn:null,totals_mode:'percentages'});
 expect(screen.getByText(/convênio ativo na NFS-e Nacional/)).toBeTruthy();  // ISS guidance for non-optants
 expect(screen.queryByLabelText('Situação no Simples Nacional')).toBeNull();     // regime is chosen once, above
 expect(companyProblems(state())).toEqual([]);
 expect(companyPayload(state()).cnpj).toBe('11222333000181');
 fireEvent.click(screen.getByRole('radio',{name:/Simples Nacional/}));
 expect(state().config.perfil_fiscal).toMatchObject({op_simp_nac:'3',reg_ap_trib_sn:'1',totals_mode:'simples_percent'});
});

it('customer form: CNPJ requires the address, CPF does not',async()=>{
 render(<Harness kind="customer" initial={{company_id:1,document:'',name:'',details:{}}}/>);
 fireEvent.change(screen.getByLabelText(/^CPF ou CNPJ/),{target:{value:'52998224725'}});
 fireEvent.change(screen.getByLabelText('Nome completo'),{target:{value:'MARIA'}});
 expect(screen.getByText('opcional para CPF')).toBeTruthy();expect(customerProblems(state())).toEqual([]);
 fireEvent.change(screen.getByLabelText(/^CPF ou CNPJ/),{target:{value:'11.444.777/0001-61'}});
 expect(screen.getByText('obrigatório para CNPJ')).toBeTruthy();expect(screen.getByLabelText('Razão social')).toBeTruthy();
 expect(customerProblems(state())).toEqual(['CEP com 8 dígitos','cidade escolhida na lista','logradouro','número','bairro']);
 fireEvent.change(screen.getByLabelText('CEP'),{target:{value:'88495-000'}});
 fireEvent.change(screen.getByLabelText('Logradouro'),{target:{value:'RUA A'}});
 fireEvent.change(screen.getByLabelText('Número'),{target:{value:'10'}});
 fireEvent.change(screen.getByLabelText('Bairro'),{target:{value:'CENTRO'}});
 fireEvent.change(screen.getByLabelText(/^Cidade/),{target:{value:'garop'}});
 fireEvent.mouseDown(await screen.findByRole('option',{name:/Garopaba/}));
 expect(customerProblems(state())).toEqual([]);
 expect(customerPayload(state())).toMatchObject({document:'11444777000161',details:{cep:'88495000',municipio_ibge:'4205704'}});
});

it('emitting for Lucro Presumido asks the federal, state and municipal percentages',async()=>{
 const lp={id:1,cnpj:'11222333000181',name:'EMPRESA LP',config:{municipio_ibge:'4205704',perfil_fiscal:{series:'1',op_simp_nac:'1',reg_ap_trib_sn:null,reg_esp_trib:'0',totals_mode:'percentages',include_provider_im:false,include_iss_rate:false}}};
 const raw={cnpj_emitente:'11222333000181',nome_tomador:'CLIENTE A',documento_tomador:'52998224725',competencia:'2026-11-01',descricao_servico:'SERVICO',valor_servico:'100.00'};
 const note={id:7,batch_id:3,batch_revision:4,company_id:1,raw,errors:[],amount_cents:10000,situation:'Pronta',dps:null,editable:true};
 vi.spyOn(HTMLAnchorElement.prototype,'click').mockImplementation(()=>{});
 const call=vi.fn().mockResolvedValueOnce([note]).mockResolvedValueOnce({last_simples_percent:null,last_percentages:{fed:'13.45',est:'0.00',mun:'2.00'}}).mockResolvedValueOnce({id:9,identifier:'DPSX',series:'1',number:1,existing:false}).mockResolvedValueOnce([note]);
 render(<Notas api={call} companies={[lp]} customers={[]} services={[]} role="admin"/>);
 fireEvent.click(await screen.findByRole('button',{name:/Emitir/}));
 const dialog=screen.getByRole('dialog');
 expect(dialog.textContent).toContain('Não optante (Lucro Presumido/Real)');expect(within(dialog).queryByLabelText(/Simples/)).toBeNull();
 const fed=within(dialog).getByLabelText('Federais (%)') as HTMLInputElement;await waitFor(()=>expect(fed.value).toBe('13.45'));
 fireEvent.change(fed,{target:{value:'13,50'}});
 fireEvent.click(within(dialog).getByRole('checkbox',{name:/Conferi emitente/}));fireEvent.click(within(dialog).getByRole('checkbox',{name:/Abrir o conector/}));
 fireEvent.submit(within(dialog).getByRole('button',{name:/Reservar e baixar XML/}).closest('form')!);
 await waitFor(()=>expect(call.mock.calls[2]).toEqual(['/notes/7/emit','POST',{batch_revision:4,expected_raw:raw,confirm:true,tot_fed:'13.50',tot_est:'0.00',tot_mun:'2.00'}]));
});
