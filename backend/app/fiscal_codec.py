"""SEFIN wire codec only. Does not generate/sign/validate DPS or send HTTP requests."""
import base64
import binascii
import gzip
import io
MAX_XML=2*1024*1024

def encode_dps_envelope(xml:bytes)->dict[str,str]:
    if not isinstance(xml,bytes) or not xml or len(xml)>MAX_XML:
        raise ValueError('XML vazio ou acima do limite de 2 MB.')
    return {'dpsXmlGZipB64':base64.b64encode(gzip.compress(xml,mtime=0)).decode('ascii')}

def decode_xml_envelope(encoded:str)->bytes:
    if not isinstance(encoded,str) or not encoded or len(encoded)>4*MAX_XML:
        raise ValueError('Conteúdo compactado ausente ou excessivo.')
    try:
        compressed=base64.b64decode(encoded,validate=True)
        with gzip.GzipFile(fileobj=io.BytesIO(compressed)) as stream:
            xml=stream.read(MAX_XML+1)
    except (ValueError,binascii.Error,OSError,EOFError):
        raise ValueError('Conteúdo GZip/Base64 inválido.') from None
    if not xml or len(xml)>MAX_XML:raise ValueError('XML descompactado vazio ou acima de 2 MB.')
    return xml
