
keytool -genkey -storetype jks -keystore cert.jks -keyalg RSA -keysize 2048 -startdate "2025/06/10 00:00:00" -validity 365

    <Connector port="8443" protocol="org.apache.coyote.http11.Http11NioProtocol"
               maxThreads="150" SSLEnabled="true"
               scheme="https" secure="true"
               clientAuth="false" sslProtocol="TLS"
               keystoreFile="/data/tomcat/cert.jks" keystorePass="1234">
    </Connector>