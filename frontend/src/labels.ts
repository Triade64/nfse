// Field names shown to people. Validation messages from the API start with the technical key ("valor_servico: ...").
export const FIELD_LABELS:Record<string,string>={cnpj_emitente:'CNPJ emitente',documento_tomador:'CPF/CNPJ tomador',nome_tomador:'Nome do tomador',competencia:'Competência',municipio_ibge:'Município IBGE',descricao_servico:'Descrição do serviço',codigo_tributacao_nacional:'Tributação nacional',codigo_tributacao_municipal:'Tributação municipal',codigo_nbs:'Código NBS (opcional)',valor_servico:'Valor do serviço',iss_aliquota:'Alíquota ISS (%)',iss_retido:'ISS retido (sim/nao)',retencoes:'Retenções (JSON em reais)',observacoes:'Observações'};

// Short labels for messages (without the hints in parentheses used on form fields).
const SHORT:Record<string,string>={...FIELD_LABELS,codigo_nbs:'Código NBS',iss_aliquota:'Alíquota do ISS',iss_retido:'ISS retido',retencoes:'Retenções'};

/** "valor_servico: informe..." -> "Valor do serviço: informe...". Messages without a known field key stay as they are. */
export function readableError(message:string):string{
 const match=/^([a-z_]+):\s*(.*)$/s.exec(message);
 return match&&SHORT[match[1]]?`${SHORT[match[1]]}: ${match[2]}`:message;
}

/** A note whose value did not validate has no meaningful amount to show. */
export function hasInvalidValue(errors:string[]):boolean{
 return errors.some(e=>e.startsWith('valor_servico:'));
}
