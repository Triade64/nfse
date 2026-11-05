import base64,gzip,json
from pathlib import Path
import pytest
from app.fiscal_codec import encode_dps_envelope,decode_xml_envelope,MAX_XML

def test_envelope_matches_uploaded_contract():
    contract=json.loads((Path(__file__).resolve().parents[2]/'docs/official/sefin-restricted-v1.swagger.json').read_text(encoding='utf-8-sig'))
    assert contract['definitions']['NFSePostRequest']['required']==['dpsXmlGZipB64']
    xml='<DPS>EXEMPLO FICTÍCIO, NÃO ASSINADO E SEM VALIDADE</DPS>'.encode()
    payload=encode_dps_envelope(xml)
    assert list(payload)==['dpsXmlGZipB64'] and decode_xml_envelope(payload['dpsXmlGZipB64'])==xml

def test_codec_refuses_invalid_and_oversized_input():
    for value in ['', 'not-base64',base64.b64encode(b'not-gzip').decode(),base64.b64encode(gzip.compress(b'x'*(MAX_XML+1))).decode()]:
        with pytest.raises(ValueError):decode_xml_envelope(value)
    with pytest.raises(ValueError):encode_dps_envelope(b'')
    with pytest.raises(ValueError):encode_dps_envelope(b'x'*(MAX_XML+1))
