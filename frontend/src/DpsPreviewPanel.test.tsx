// @vitest-environment jsdom
import React from 'react';
import {render,screen,fireEvent,waitFor,cleanup} from '@testing-library/react';
import {afterEach,expect,it,vi} from 'vitest';
import {DpsPreviewPanel} from './DpsPreviewPanel';
afterEach(()=>{cleanup();vi.unstubAllGlobals()});
it('requires explicit fiscal choices and reports a changed draft without downloading',async()=>{
 const raw={cnpj_emitente:'11222333000181',nome_tomador:'FICTICIO',competencia:'2026-11-05',valor_servico:'10.00',iss_aliquota:'2.00'};
 const fetcher=vi.fn().mockResolvedValueOnce({ok:true,json:async()=>[{id:7,batch_id:2,raw}]}).mockResolvedValueOnce({ok:true,json:async()=>({revision:3})}).mockResolvedValueOnce({ok:false,json:async()=>({detail:'Rascunho alterado. Recarregue a tela antes de gerar a prévia.'})});
 vi.stubGlobal('fetch',fetcher);render(<DpsPreviewPanel/>);
 const button=screen.getByRole('button',{name:'Validar XSD e baixar prévia XML'}) as HTMLButtonElement;
 expect(button.disabled).toBe(true);
 await screen.findByRole('option',{name:/#7/});expect(fetcher).toHaveBeenCalledTimes(1);
 fireEvent.change(screen.getByLabelText('Rascunho'),{target:{value:'7'}});
 for(const label of ['Situação no Simples Nacional','Regime especial municipal','Informação da alíquota de ISS','Informação dos tributos totais'])expect((screen.getByLabelText(label) as HTMLSelectElement).value).toBe('');
 const inputs:Record<string,string>={'CNPJ do próprio escritório':'11222333000181','Série de teste (não reservada)':'12','Número da DPS de teste (não reservado)':'1','Emissão — fuso deste computador':'2026-11-05T10:00','Situação no Simples Nacional':'3','Regime especial municipal':'0','Informação da alíquota de ISS':'omit','Informação dos tributos totais':'simples_percent'};
 for(const [label,value] of Object.entries(inputs))fireEvent.change(screen.getByLabelText(label),{target:{value}});
 fireEvent.change(screen.getByLabelText('Regime de apuração SN'),{target:{value:'1'}});
 fireEvent.change(screen.getByLabelText('Percentual total SN'),{target:{value:'6.00'}});
 expect(button.disabled).toBe(true);fireEvent.click(screen.getByRole('checkbox'));
 fireEvent.submit(button.closest('form')!);
 await waitFor(()=>expect(screen.getByRole('alert').textContent).toContain('Rascunho alterado'));
 const [url,init]=fetcher.mock.calls[2];expect(url).toBe('/api/drafts/7/restricted-preview');
 const payload=JSON.parse(init.body);expect(payload.expected_raw).toEqual(raw);expect(payload.confirm_offline).toBe(true);expect(payload.include_iss_rate).toBe(false);
});
