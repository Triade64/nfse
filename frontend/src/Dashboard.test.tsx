// @vitest-environment jsdom
import React from 'react';
import {render,screen,fireEvent,cleanup,within} from '@testing-library/react';
import {afterEach,expect,it,vi} from 'vitest';
import {Dashboard} from './Dashboard';
import {EnvironmentBanner} from './EnvironmentBanner';
import {Notas} from './Notas';
import {readableError} from './labels';
afterEach(()=>{cleanup();vi.restoreAllMocks()});

const office={id:1,cnpj:'11222333000181',name:'ESCRITORIO',config:{municipio_ibge:'4205704',ambiente:'1'}};
const client={id:2,cnpj:'11444777000161',name:'CLIENTE',config:{municipio_ibge:'4205704'}};
const raw=(over={})=>({cnpj_emitente:'11222333000181',nome_tomador:'CLIENTE A',documento_tomador:'52998224725',competencia:'2026-11-05',descricao_servico:'HONORARIOS',valor_servico:'1500.00',...over});
const note=(id:number,situation:string,over:any={})=>({id,batch_id:id,batch_revision:1,company_id:1,raw:raw(),errors:[],amount_cents:150000,situation,dps:null,editable:true,...over});
const authorized=(id:number,competencia:string,env='1')=>note(id,'NFS-e autorizada',{raw:raw({competencia}),dps:{id,status:'Autorizada',series:'1',number:id,environment:env,has_danfse:true,result_at:'2026-11-0'+id}});

it('dashboard counts notes and opens Notas already filtered',async()=>{
 const notes=[authorized(1,'2026-11-01'),authorized(2,'2026-10-01'),note(3,'Pronta'),note(4,'DPS reservada',{dps:{id:9,status:'Reservada',environment:'1'}}),note(5,'DPS em consulta',{dps:{id:8,status:'Desconhecida',environment:'1'}}),note(6,'DPS rejeitada'),note(7,'Com inconsistência')];
 const open=vi.fn();
 render(<Dashboard api={vi.fn().mockResolvedValue(notes)} companies={[office,client]} openNotes={open} today={new Date('2026-11-13T12:00:00')}/>);
 const month=await screen.findByRole('button',{name:/Autorizadas em novembro de 2026/});
 expect(month.textContent).toContain('1');expect(month.textContent).toMatch(/R\$\s1\.500,00/);  // only November's competence
 const waiting=screen.getByRole('button',{name:/Aguardando o conector/});expect(within(waiting).getByText('2')).toBeTruthy();
 fireEvent.click(waiting);expect(open).toHaveBeenCalledWith({situation:'Aguardando o conector'});
 fireEvent.click(month);expect(open).toHaveBeenLastCalledWith({situation:'NFS-e autorizada',month:'2026-11'});
 expect(screen.getAllByText('DANFSe').length).toBe(2);
});

it('environment banner tells the truth about production',()=>{
 const {container,rerender}=render(<EnvironmentBanner companies={[{...client}]}/>);
 expect(container.textContent).toContain('produção restrita (testes)');
 rerender(<EnvironmentBanner companies={[office,client]}/>);
 expect(container.textContent).toContain('Produção ativa');expect(container.textContent).toContain('Em produção: ESCRITORIO');
 expect(container.textContent).not.toContain('Emissão real bloqueada');
});

it('errors use field names and an invalid value is not shown as zero',async()=>{
 expect(readableError('valor_servico: informe valor positivo')).toBe('Valor do serviço: informe valor positivo');
 expect(readableError('Documento repetido: já existe rascunho')).toBe('Documento repetido: já existe rascunho');
 const bad=note(1,'Com inconsistência',{errors:['valor_servico: informe valor positivo com até duas casas decimais'],amount_cents:0,raw:raw({valor_servico:'abc'})});
 render(<Notas api={vi.fn().mockResolvedValue([bad])} companies={[office]} customers={[]} services={[]} role="admin"/>);
 expect(await screen.findByText('Valor do serviço: informe valor positivo com até duas casas decimais')).toBeTruthy();
 expect(screen.getByTitle('Valor inválido').textContent).toBe('—');
 expect(screen.queryByText('valor_servico',{exact:false})).toBeNull();
});

it('Notas starts with the filter chosen on the dashboard and filters by environment',async()=>{
 const notes=[note(1,'DPS reservada',{dps:{id:1,status:'Reservada',environment:'1',series:'1',number:1}}),note(2,'DPS em consulta',{company_id:2,raw:raw({nome_tomador:'CLIENTE B'}),dps:{id:2,status:'Desconhecida',environment:'2',series:'1',number:2}}),note(3,'Pronta',{raw:raw({nome_tomador:'CLIENTE C'})})];
 render(<Notas api={vi.fn().mockResolvedValue(notes)} companies={[office,client]} customers={[]} services={[]} role="admin" initialFilter={{situation:'Aguardando o conector'}}/>);
 await screen.findByText('2 notas',{exact:false});
 expect(screen.queryByText('CLIENTE C')).toBeNull();
 fireEvent.change(screen.getByLabelText('Filtrar ambiente'),{target:{value:'2'}});
 expect(screen.getByText('CLIENTE B')).toBeTruthy();expect(screen.getByText('1 nota',{exact:false})).toBeTruthy();
 expect(screen.getByText('TESTE')).toBeTruthy();
});

it('imports a spreadsheet straight into Notas',async()=>{
 const api=vi.fn().mockResolvedValueOnce([]).mockResolvedValueOnce({created:3,with_errors:1}).mockResolvedValueOnce([note(1,'Pronta')]);
 const {container}=render(<Notas api={api} companies={[office]} customers={[]} services={[]} role="operator"/>);
 await screen.findByText('0 notas',{exact:false});
 expect(screen.getByRole('link',{name:/Modelo/}).getAttribute('href')).toBe('/api/template.xlsx');
 fireEvent.change(container.querySelector('input[type="file"]')!,{target:{files:[new File(['x'],'notas.xlsx')]}});
 expect((await screen.findByRole('status')).textContent).toContain('3 notas importadas; 1 com inconsistência');
 expect(api.mock.calls[1][0]).toBe('/import?per_note=true');
});
