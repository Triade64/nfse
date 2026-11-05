// @vitest-environment jsdom
import React from 'react';
import {render,screen,fireEvent,waitFor,cleanup,within} from '@testing-library/react';
import {afterEach,expect,it,vi} from 'vitest';
import {Notas} from './Notas';
afterEach(()=>{cleanup();vi.restoreAllMocks()});
const companies=[{id:1,cnpj:'11222333000181',name:'ESCRITORIO',config:{municipio_ibge:'4205704',perfil_fiscal:{series:'1',op_simp_nac:'3',reg_ap_trib_sn:'1',reg_esp_trib:'0',totals_mode:'simples_percent',include_provider_im:false,include_iss_rate:false}}}];
const raw={cnpj_emitente:'11222333000181',nome_tomador:'CLIENTE A',documento_tomador:'52998224725',competencia:'2026-10-01',descricao_servico:'HONORARIOS',valor_servico:'1500.00'};
const ready={id:7,batch_id:3,batch_revision:4,company_id:1,raw,errors:[],amount_cents:150000,situation:'Pronta',dps:null,editable:true};
const reserved={...ready,id:8,raw:{...raw,nome_tomador:'CLIENTE B'},situation:'DPS reservada',editable:false,dps:{id:5,series:'1',number:2,status:'Reservada',identifier:'DPSX'}};

it('duplicates selected notes to a chosen date only after explicit review',async()=>{
 const api=vi.fn().mockResolvedValueOnce([ready,reserved]).mockResolvedValueOnce({created:[20,21]}).mockResolvedValueOnce([ready,reserved]);
 render(<Notas api={api} companies={companies} customers={[]} services={[]} role="operator"/>);
 await screen.findByText('CLIENTE A');
 expect(screen.queryByRole('button',{name:/Emitir/})).toBeNull();  // operators do not emit
 fireEvent.click(screen.getByLabelText('Selecionar todas as notas visíveis'));
 fireEvent.click(screen.getByRole('button',{name:/Duplicar 2 selecionadas/}));
 const dialog=screen.getByRole('dialog');const submit=within(dialog).getByRole('button',{name:/Duplicar/}) as HTMLButtonElement;
 fireEvent.change(within(dialog).getByLabelText('Nova competência'),{target:{value:'2026-11-01'}});
 expect(submit.disabled).toBe(true);fireEvent.click(within(dialog).getByRole('checkbox'));expect(submit.disabled).toBe(false);
 fireEvent.submit(submit.closest('form')!);
 await waitFor(()=>expect(screen.getByRole('status').textContent).toContain('2 notas criadas para 01/11/2026'));
 const [path,method,body]=api.mock.calls[1];expect(path).toBe('/notes/duplicate');expect(method).toBe('POST');
 expect(body.draft_ids).toEqual([7,8]);expect(body.competencia).toBe('2026-11-01');expect(body.confirm_review).toBe(true);expect(body.request_id).toMatch(/^[0-9a-f-]{36}$/);
});

it('admin emits a ready note with the company profile and downloads the XML',async()=>{
 const click=vi.spyOn(HTMLAnchorElement.prototype,'click').mockImplementation(()=>{});
 const api=vi.fn().mockResolvedValueOnce([ready,reserved]).mockResolvedValueOnce({last_simples_percent:'6.54'}).mockResolvedValueOnce({id:9,identifier:'DPS0003',series:'1',number:3,existing:false}).mockResolvedValueOnce([ready]);
 render(<Notas api={api} companies={companies} customers={[]} services={[]} role="admin"/>);
 await screen.findByText('CLIENTE A');
 expect(screen.getAllByRole('button',{name:/Emitir/})).toHaveLength(1);  // only the ready note
 expect(screen.getByRole('button',{name:/Descartar/})).toBeTruthy();     // reserved note can be discarded
 fireEvent.click(screen.getByRole('button',{name:/Emitir/}));
 const dialog=screen.getByRole('dialog');expect(dialog.textContent).toContain('IM omitida');expect(dialog.textContent).toContain('alíquota omitida');
 const percent=within(dialog).getByLabelText(/Percentual aproximado/) as HTMLInputElement;await waitFor(()=>expect(percent.value).toBe('6.54'));
 fireEvent.change(percent,{target:{value:'7,12'}});
 fireEvent.click(within(dialog).getByRole('checkbox'));fireEvent.submit(within(dialog).getByRole('button',{name:/Reservar e baixar XML/}).closest('form')!);
 await waitFor(()=>expect(screen.getByRole('status').textContent).toContain('série 1, nº 3'));
 expect(api.mock.calls[1]).toEqual(['/companies/1/fiscal-defaults']);
 expect(api.mock.calls[2]).toEqual(['/notes/7/emit','POST',{batch_revision:4,expected_raw:raw,confirm:true,simples_percent:'7.12'}]);
 expect(click).toHaveBeenCalled();
});

it('shows API refusal inside the duplicate dialog',async()=>{
 const api=vi.fn().mockResolvedValueOnce([ready]).mockRejectedValueOnce(new Error('Já existe nota igual nesta competência para: CLIENTE A (1500.00).'));
 render(<Notas api={api} companies={companies} customers={[]} services={[]} role="operator"/>);
 fireEvent.click(await screen.findByRole('button',{name:/^Duplicar$/}));
 const dialog=screen.getByRole('dialog');
 fireEvent.change(within(dialog).getByLabelText('Nova competência'),{target:{value:'2026-10-01'}});fireEvent.click(within(dialog).getByRole('checkbox'));
 fireEvent.submit(within(dialog).getByRole('button',{name:/Duplicar/}).closest('form')!);
 await waitFor(()=>expect(within(dialog).getByRole('alert').textContent).toContain('nota igual'));
});

it('hides Emitir and explains E0235 when a CNPJ customer has no address',async()=>{
 const pj={...ready,id:11,raw:{...raw,documento_tomador:'11222333000181',nome_tomador:'CLIENTE PJ'},address_missing:true};
 const api=vi.fn().mockResolvedValueOnce([pj]);
 render(<Notas api={api} companies={companies} customers={[]} services={[]} role="admin"/>);
 await screen.findByText('CLIENTE PJ');
 expect(screen.queryByRole('button',{name:/Emitir/})).toBeNull();
 expect(screen.getByText(/E0235/)).toBeTruthy();
});

it('new note offers the official NBS list and the accounting suggestion for 171901',async()=>{
 const api=vi.fn(async(path:string,method?:string,body?:any)=>{
  if(path==='/notes')return [];
  if(path==='/nbs')return [{code:'113022100',formatted:'1.1302.21.00',description:'Serviços de contabilidade'}];
  if(path==='/batches'&&method==='POST')return {id:1,body};
  throw new Error('inesperado '+path);
 });
 render(<Notas api={api} companies={companies} customers={[]} services={[]} role="operator"/>);
 fireEvent.click(await screen.findByRole('button',{name:/Nova nota/}));
 const dialog=screen.getByRole('dialog');
 await waitFor(()=>expect(api).toHaveBeenCalledWith('/nbs'));
 fireEvent.change(within(dialog).getByLabelText('Código tributação nacional'),{target:{value:'171901'}});
 fireEvent.click(within(dialog).getByRole('button',{name:/Usar 1.1302.21.00/}));
 const nbs=within(dialog).getByLabelText(/Código NBS/) as HTMLInputElement;
 expect(nbs.value).toBe('1.1302.21.00 — Serviços de contabilidade');
 for(const [label,value] of Object.entries({'CPF / CNPJ do tomador':'52998224725','Nome do tomador':'CLIENTE','Competência':'2026-10-01','Descrição do serviço':'HONORARIOS','Valor (R$)':'10,00','Alíquota ISS (%)':'2'}))fireEvent.change(within(dialog).getByLabelText(label),{target:{value}});
 fireEvent.submit(within(dialog).getByRole('button',{name:/Salvar nota/}).closest('form')!);
 await waitFor(()=>expect(api).toHaveBeenCalledWith('/batches','POST',expect.anything()));
 const sent=api.mock.calls.find(c=>c[0]==='/batches')![2];
 expect(sent.rows[0].codigo_nbs).toBe('1.1302.21.00');
});
