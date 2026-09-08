// SPDX-FileCopyrightText: 2026 Bundesamt für Informatik und Telekommunikation BIT
// SPDX-License-Identifier: GPL-2.0-or-later

#include "cli/environmentbootstraputility.hpp"
#include "cli/apisetuputility.hpp"
#include "cli/featureutility.hpp"
#include "cli/nodesetupcommand.hpp"
#include "cli/nodeutility.hpp"
#include "remote/apilistener.hpp"
#include "remote/pkiutility.hpp"
#include "base/atomic-file.hpp"
#include "base/application.hpp"
#include "base/base64.hpp"
#include "base/configuration.hpp"
#include "base/convert.hpp"
#include "base/exception.hpp"
#include "base/io-engine.hpp"
#include "base/json.hpp"
#include "base/logger.hpp"
#include "base/networkstream.hpp"
#include "base/tlsutility.hpp"
#include "base/tlsstream.hpp"
#include "base/utility.hpp"

#include <boost/any.hpp>
#include <boost/beast/core/flat_buffer.hpp>
#include <boost/beast/http/field.hpp>
#include <boost/beast/http/message.hpp>
#include <boost/beast/http/parser.hpp>
#include <boost/beast/http/read.hpp>
#include <boost/beast/http/status.hpp>
#include <boost/beast/http/string_body.hpp>
#include <boost/beast/http/verb.hpp>
#include <boost/beast/http/write.hpp>
#include <boost/program_options.hpp>
#include <boost/asio/connect.hpp>
#include <boost/asio/ip/tcp.hpp>
#include <boost/asio/spawn.hpp>
#include <openssl/pem.h>
#include <chrono>
#include <cctype>
#include <exception>
#include <fstream>
#include <sstream>
#include <stdexcept>
#include <utility>
#include <vector>

using namespace icinga;
namespace po = boost::program_options;

namespace
{

String Env(const String& name, const String& fallback = String())
{
	String value = Utility::GetFromEnvironment(name);
	return value.IsEmpty() ? fallback : value;
}

bool EnvBool(const String& name, bool fallback = false)
{
	String value = Env(name);
	if (value.IsEmpty())
		return fallback;
	String normalized = value.ToLower();
	if (normalized == "1" || normalized == "true" || normalized == "yes")
		return true;
	if (normalized == "0" || normalized == "false" || normalized == "no")
		return false;
	BOOST_THROW_EXCEPTION(std::invalid_argument(
		name + " must be one of true, false, yes, no, 1 or 0"));
}

String RequireEnv(const String& name)
{
	String value = Env(name);
	if (value.IsEmpty())
		BOOST_THROW_EXCEPTION(std::invalid_argument("Required environment variable " + name + " is empty"));
	return value;
}

void ValidateName(const String& value, const String& variable)
{
	for (char c : value.GetData()) {
		if (!(std::isalnum(static_cast<unsigned char>(c)) || c == '_' || c == '.' || c == '-'))
			BOOST_THROW_EXCEPTION(std::invalid_argument(variable + " contains unsafe characters"));
	}
	if (value.IsEmpty())
		BOOST_THROW_EXCEPTION(std::invalid_argument(variable + " is empty"));
}

void ValidateAddress(const String& value, const String& variable)
{
	if (value.IsEmpty())
		BOOST_THROW_EXCEPTION(std::invalid_argument(variable + " is empty"));
	for (char c : value.GetData()) {
		if (!(std::isalnum(static_cast<unsigned char>(c)) || c == '.' || c == '-' || c == ':'))
			BOOST_THROW_EXCEPTION(std::invalid_argument(variable + " contains unsafe characters"));
	}
}

String ReadFile(const String& path)
{
	std::ifstream input(path.CStr(), std::ios::binary);
	if (!input)
		BOOST_THROW_EXCEPTION(std::runtime_error("Cannot read " + path));
	std::ostringstream content;
	content << input.rdbuf();
	return content.str();
}

template<class T>
void SetOption(po::variables_map& vm, const std::string& name, T value)
{
	vm.insert(std::make_pair(name, po::variable_value(boost::any(std::move(value)), false)));
}

void SetSwitch(po::variables_map& vm, const std::string& name)
{
	SetOption(vm, name, true);
}

bool IsPrimaryOrdinal()
{
	String pod = RequireEnv("ICINGA2_POD_NAME");
	return pod.GetLength() >= 2 && pod.SubStr(pod.GetLength() - 2) == "-0";
}

String TicketSalt()
{
	String salt = Env("ICINGA2_TICKET_SALT");
	if (salt.IsEmpty())
		BOOST_THROW_EXCEPTION(std::invalid_argument(
			"ICINGA2_TICKET_SALT is required for declarative PKI bootstrap"));
	return salt;
}

struct BootstrapEndpoint
{
	String name;
	String address;
	String port;
};

struct BootstrapTicket
{
	String ticket;
	std::shared_ptr<X509> parentCertificate;
};

void ValidatePort(const String& value, const String& variable)
{
	try {
		long port = Convert::ToLong(value);
		if (port < 1 || port > 65535)
			BOOST_THROW_EXCEPTION(std::invalid_argument(variable + " is outside 1..65535"));
	} catch (const std::exception&) {
		BOOST_THROW_EXCEPTION(std::invalid_argument(variable + " is invalid"));
	}
}

BootstrapTicket RequestTicket(const BootstrapEndpoint& parent, const String& bootstrapCaFile,
	const String& commonName)
{
	namespace beast = boost::beast;
	namespace http = beast::http;

	String username = RequireEnv("ICINGA2_PARENT_API_USER");
	String password = RequireEnv("ICINGA2_PARENT_API_PASSWORD");
	auto sslContext = MakeAsioSslContext(String(), String(), bootstrapCaFile);
	boost::asio::io_context bootstrapIo;
	auto stream = Shared<AsioTlsStream>::Make(
		bootstrapIo, *sslContext, parent.name);
	std::exception_ptr operationError;
	std::shared_ptr<X509> peerCertificate;
	http::response<http::string_body> response;
	auto strand = std::make_shared<boost::asio::io_context::strand>(bootstrapIo);

	IoEngine::SpawnCoroutine(*strand, [&](boost::asio::yield_context yc) {
		try {
			boost::asio::ip::tcp::resolver resolver(bootstrapIo);
			Timeout timeout(*strand, std::chrono::seconds(10), [&] {
				resolver.cancel();
				stream->ForceDisconnect();
			});
			auto addresses = resolver.async_resolve(parent.address.GetData(), parent.port.GetData(), yc);
			boost::asio::async_connect(stream->lowest_layer(), addresses, yc);
			stream->lowest_layer().set_option(boost::asio::ip::tcp::socket::keep_alive(true));
			auto& tlsStream = stream->next_layer();
			tlsStream.async_handshake(tlsStream.client, yc);
			peerCertificate = tlsStream.GetPeerCertificate();
			if (!tlsStream.IsVerifyOK() || !peerCertificate || GetCertificateCN(peerCertificate) != parent.name)
				BOOST_THROW_EXCEPTION(std::runtime_error(
					"TLS trust or Icinga identity for parent '" + parent.name + "' does not match"));

			Dictionary::Ptr payload = new Dictionary({{"cn", commonName}});
			http::request<http::string_body> request(
				http::verb::post, "/v1/actions/generate-ticket", 10);
			request.set(http::field::host, parent.name + ":" + parent.port);
			request.set(http::field::user_agent, "Icinga/EnvironmentBootstrap/" + Application::GetAppVersion());
			request.set(http::field::accept, "application/json");
			request.set(http::field::content_type, "application/json");
			request.set(http::field::authorization, "Basic " + Base64::Encode(username + ":" + password));
			request.body() = JsonEncode(payload);
			request.prepare_payload();

			http::async_write(*stream, request, yc);
			stream->async_flush(yc);
			http::parser<false, http::string_body> parser;
			beast::flat_buffer buffer;
			http::async_read(*stream, buffer, parser, yc);
			response = parser.release();
		} catch (...) {
			operationError = std::current_exception();
		}
	});

	bootstrapIo.run();
	if (operationError)
		std::rethrow_exception(operationError);
	if (!peerCertificate) {
		BOOST_THROW_EXCEPTION(std::runtime_error(
			"Parent '" + parent.name + "' did not present a certificate"));
	}
	if (response.result() != http::status::ok) {
		BOOST_THROW_EXCEPTION(std::runtime_error(
			"Ticket request to parent '" + parent.name + "' failed with HTTP "
			+ Convert::ToString(response.result_int())));
	}

	Dictionary::Ptr body = JsonDecode(response.body());
	Array::Ptr results = body->Get("results");
	if (!results || results->GetLength() == 0)
		BOOST_THROW_EXCEPTION(std::runtime_error("Ticket response contains no results"));
	Dictionary::Ptr result = results->Get(0);
	int code = result->Get("code");
	String ticket = result->Get("ticket");
	if (code < 200 || code > 299 || ticket.IsEmpty()) {
		String status = result->Get("status");
		BOOST_THROW_EXCEPTION(std::runtime_error(
			"Parent did not return a usable PKI ticket: " + status));
	}
	return {ticket, peerCertificate};
}

void ReconcileIntermediateCa()
{
	String certFile = RequireEnv("ICINGA2_CA_CERT_FILE");
	String keyFile = RequireEnv("ICINGA2_CA_KEY_FILE");
	String trustFile = RequireEnv("ICINGA2_CA_TRUST_FILE");
	auto certificate = GetX509Certificate(certFile);

	if (!IsCa(certificate))
		BOOST_THROW_EXCEPTION(std::invalid_argument("The supplied Icinga intermediate certificate is not a CA"));
	if (!VerifyCertificate(trustFile, certificate, String()))
		BOOST_THROW_EXCEPTION(std::invalid_argument(
			"The supplied Icinga intermediate does not validate against its corporate trust bundle"));

	BIO *keyBio = BIO_new_file(keyFile.CStr(), "r");
	if (!keyBio)
		BOOST_THROW_EXCEPTION(std::invalid_argument("Cannot read the supplied Icinga intermediate private key"));
	EVP_PKEY *privateKey = PEM_read_bio_PrivateKey(keyBio, nullptr, nullptr, nullptr);
	BIO_free(keyBio);
	if (!privateKey)
		BOOST_THROW_EXCEPTION(std::invalid_argument("The supplied Icinga intermediate private key is invalid"));
	int keyMatches = X509_check_private_key(certificate.get(), privateKey);
	EVP_PKEY_free(privateKey);
	if (keyMatches != 1)
		BOOST_THROW_EXCEPTION(std::invalid_argument(
			"The supplied Icinga intermediate certificate and private key do not match"));

	String caDir = GetIcingaCADir();
	String certDir = ApiListener::GetCertsDir();
	String archiveDir = caDir + "/trusted-roots";
	Utility::MkDirP(caDir, 0700);
	Utility::MkDirP(certDir, 0755);
	Utility::MkDirP(archiveDir, 0700);

	String newCert = CertificateToString(certificate);
	String fingerprint = SHA256(newCert);
	String currentCa = caDir + "/ca.crt";
	if (Utility::PathExists(currentCa)) {
		String oldCert = ReadFile(currentCa);
		String oldFingerprint = SHA256(oldCert);
		if (oldFingerprint != fingerprint) {
			AtomicFile::Write(archiveDir + "/" + oldFingerprint + ".crt", 0644, oldCert);
			Log(LogInformation, "EnvironmentBootstrap")
				<< "Retained the previous Icinga intermediate as a trust anchor.";
		}
	}

	AtomicFile::Write(currentCa, 0644, newCert);
	AtomicFile::Write(caDir + "/ca.key", 0600, ReadFile(keyFile));
	AtomicFile::Write(caDir + "/corporate-intermediate", 0600, "managed\n");

	String trustBundle = ReadFile(trustFile) + "\n" + newCert;
	Utility::Glob(archiveDir + "/*.crt", [&trustBundle](const String& oldCert) {
		trustBundle += "\n" + ReadFile(oldCert);
	}, GlobFile);
	AtomicFile::Write(certDir + "/ca.crt", 0644, trustBundle);
}

void ValidateEndpoint(const BootstrapEndpoint& endpoint);

BootstrapEndpoint Parent(unsigned int index)
{
	String suffix = Convert::ToString(index);
	BootstrapEndpoint endpoint {
		RequireEnv("ICINGA2_PARENT_ENDPOINT_" + suffix + "_NAME"),
		RequireEnv("ICINGA2_PARENT_ENDPOINT_" + suffix + "_ADDRESS"),
		RequireEnv("ICINGA2_PARENT_ENDPOINT_" + suffix + "_PORT")
	};
	ValidateEndpoint(endpoint);
	return endpoint;
}

void ValidateEndpoint(const BootstrapEndpoint& endpoint)
{
	ValidateName(endpoint.name, "parent endpoint name");
	ValidateAddress(endpoint.address, "parent endpoint address");
	ValidatePort(endpoint.port, "parent endpoint port");
}

void ValidateHaTopology(bool rootZone, const String& host, const String& zone)
{
	String endpoint0 = RequireEnv("ICINGA2_HA_ENDPOINT_0_NAME");
	String endpoint1 = RequireEnv("ICINGA2_HA_ENDPOINT_1_NAME");
	ValidateName(endpoint0, "ICINGA2_HA_ENDPOINT_0_NAME");
	ValidateName(endpoint1, "ICINGA2_HA_ENDPOINT_1_NAME");
	ValidateAddress(RequireEnv("ICINGA2_HA_ENDPOINT_0_HOST"), "ICINGA2_HA_ENDPOINT_0_HOST");
	ValidateAddress(RequireEnv("ICINGA2_HA_ENDPOINT_1_HOST"), "ICINGA2_HA_ENDPOINT_1_HOST");
	if (endpoint0 == endpoint1)
		BOOST_THROW_EXCEPTION(std::invalid_argument("The two HA endpoint names must be distinct"));
	if (host != endpoint0 && host != endpoint1)
		BOOST_THROW_EXCEPTION(std::invalid_argument(
			"ICINGA2_HOST must match one of the two HA endpoint names"));

	if (!rootZone) {
		String parentZone = RequireEnv("ICINGA2_PARENT_ZONE");
		ValidateName(parentZone, "ICINGA2_PARENT_ZONE");
		if (parentZone == zone)
			BOOST_THROW_EXCEPTION(std::invalid_argument(
				"ICINGA2_PARENT_ZONE must differ from ICINGA2_ZONE"));
		BootstrapEndpoint parent0 = Parent(0);
		BootstrapEndpoint parent1 = Parent(1);
		if (parent0.name == parent1.name
			|| (parent0.address == parent1.address && parent0.port == parent1.port)) {
			BOOST_THROW_EXCEPTION(std::invalid_argument(
				"The two parent endpoints must address distinct Icinga listeners"));
		}
	}
}

void WriteHaZones(bool rootZone, const String& host, const String& zone)
{
	String endpoint0 = RequireEnv("ICINGA2_HA_ENDPOINT_0_NAME");
	String address0 = RequireEnv("ICINGA2_HA_ENDPOINT_0_HOST");
	String endpoint1 = RequireEnv("ICINGA2_HA_ENDPOINT_1_NAME");
	String address1 = RequireEnv("ICINGA2_HA_ENDPOINT_1_HOST");
	String port = Env("ICINGA2_PORT", "5665");
	ValidateName(host, "ICINGA2_HOST");
	ValidateName(zone, "ICINGA2_ZONE");
	ValidateName(endpoint0, "ICINGA2_HA_ENDPOINT_0_NAME");
	ValidateName(endpoint1, "ICINGA2_HA_ENDPOINT_1_NAME");
	ValidateAddress(address0, "ICINGA2_HA_ENDPOINT_0_HOST");
	ValidateAddress(address1, "ICINGA2_HA_ENDPOINT_1_HOST");
	ValidatePort(port, "ICINGA2_PORT");

	std::ostringstream config;
	auto writeEndpoint = [&](const String& name, const String& address) {
		config << "object Endpoint \"" << name << "\" {\n";
		if (name != host)
			config << "  host = \"" << address << "\"\n  port = " << port << "\n";
		config << "}\n";
	};
	writeEndpoint(endpoint0, address0);
	writeEndpoint(endpoint1, address1);
	config << "object Zone \"" << zone << "\" {\n"
		<< "  endpoints = [ \"" << endpoint0 << "\", \"" << endpoint1 << "\" ]\n}\n"
		<< "object Zone \"global-templates\" { global = true }\n"
		<< "object Zone \"director-global\" { global = true }\n";

	if (!rootZone) {
		BootstrapEndpoint parent0 = Parent(0);
		BootstrapEndpoint parent1 = Parent(1);
		String parentZone = RequireEnv("ICINGA2_PARENT_ZONE");
		ValidateName(parentZone, "ICINGA2_PARENT_ZONE");
		for (const BootstrapEndpoint& endpoint : {parent0, parent1}) {
			config << "object Endpoint \"" << endpoint.name << "\" {\n"
				<< "  host = \"" << endpoint.address << "\"\n"
				<< "  port = " << endpoint.port << "\n}\n";
		}
		config << "object Zone \"" << parentZone << "\" {\n"
			<< "  endpoints = [ \"" << parent0.name << "\", \"" << parent1.name << "\" ]\n}\n";
	}

	AtomicFile::Write(NodeUtility::GetZonesConfPath(), 0644, config.str());
}

int SetupMaster(const String& host)
{
	return ApiSetupUtility::SetupMasterCertificates(host) ? 0 : 1;
}

void ReconcileRuntimeConfiguration(const String& host, const String& zone, const String& listen)
{
	std::vector<String> listenParts = listen.Split(",");
	if (listenParts.size() != 2)
		BOOST_THROW_EXCEPTION(std::invalid_argument("The Icinga API listen address is invalid"));

	NodeUtility::UpdateConstant("NodeName", host);
	NodeUtility::UpdateConstant("ZoneName", zone);
	FeatureUtility::EnableFeatures({"api"});
	FeatureUtility::DisableFeatures({"mainlog", "notification"});
	NodeUtility::UpdateConfiguration("\"conf.d\"", false, true);

	String apiPath = FeatureUtility::GetFeaturesAvailablePath() + "/api.conf";
	std::ostringstream api;
	api << "/** Declarative container API listener; reconciled on every start. */\n"
		<< "object ApiListener \"api\" {\n"
		<< "  bind_host = \"" << listenParts[0] << "\"\n"
		<< "  bind_port = " << listenParts[1] << "\n"
		<< "  accept_config = true\n"
		<< "  accept_commands = true\n";
	if (!Env("ICINGA2_TICKET_SALT").IsEmpty())
		api << "  ticket_salt = TicketSalt\n";
	api << "}\n";
	AtomicFile::Write(apiPath, 0644, api.str());
}

int SetupSatellite(const String& host, const String& zone, const String& listen,
	const String& parentZone, const std::vector<BootstrapEndpoint>& candidates)
{
	String bootstrapCaFile = RequireEnv("ICINGA2_BOOTSTRAP_CA_FILE");
	if (!Utility::PathExists(bootstrapCaFile))
		BOOST_THROW_EXCEPTION(std::invalid_argument(
			"ICINGA2_BOOTSTRAP_CA_FILE does not exist"));
	String trustedFile = Configuration::DataDir + "/certs/bootstrap-parent.crt";
	Utility::MkDirP(Configuration::DataDir + "/certs", 0700);
	BootstrapEndpoint parent;
	String ticket;
	bool bootstrapped = false;
	for (const BootstrapEndpoint& candidate : candidates) {
		try {
			BootstrapTicket response = RequestTicket(candidate, bootstrapCaFile, host);
			if (PkiUtility::WriteCert(response.parentCertificate, trustedFile) != 0)
				continue;
			ticket = response.ticket;
			parent = candidate;
			bootstrapped = true;
			break;
		} catch (const std::exception& ex) {
			Log(LogWarning, "EnvironmentBootstrap")
				<< "Cannot bootstrap through parent '" << candidate.name << "': "
				<< DiagnosticInformation(ex, false);
		}
	}
	if (!bootstrapped) {
		Log(LogCritical, "EnvironmentBootstrap")
			<< "No configured parent endpoint completed the PKI bootstrap.";
		return 1;
	}

	po::variables_map vm;
	SetOption(vm, "cn", host.GetData());
	SetOption(vm, "zone", zone.GetData());
	SetOption(vm, "listen", listen.GetData());
	SetOption(vm, "endpoint", std::vector<std::string> {
		(parent.name + "," + parent.address + "," + parent.port).GetData()
	});
	SetOption(vm, "parent_host", (parent.address + "," + parent.port).GetData());
	SetOption(vm, "parent_zone", parentZone.GetData());
	SetOption(vm, "ticket", ticket.GetData());
	SetOption(vm, "trustedcert", trustedFile.GetData());
	SetSwitch(vm, "accept-config");
	SetSwitch(vm, "accept-commands");
	SetSwitch(vm, "disable-confd");
	return NodeSetupCommand::SetupNode(vm);
}

}

bool EnvironmentBootstrapUtility::Run()
{
	try {
		String host = RequireEnv("ICINGA2_HOST");
		String zone = RequireEnv("ICINGA2_ZONE");
		String listenAddress = Env("ICINGA2_IP", "0.0.0.0");
		String listenPort = Env("ICINGA2_PORT", "5665");
		String listen = listenAddress + "," + listenPort;
		ValidateName(host, "ICINGA2_HOST");
		ValidateName(zone, "ICINGA2_ZONE");
		ValidateAddress(listenAddress, "ICINGA2_IP");
		ValidatePort(listenPort, "ICINGA2_PORT");
		RequireEnv("ICINGA2_API_USER");
		RequireEnv("ICINGA2_API_PASSWORD");
		if (!Env("ICINGA2_TICKET_SALT").IsEmpty()) {
			RequireEnv("ICINGA2_BOOTSTRAP_API_USER");
			RequireEnv("ICINGA2_BOOTSTRAP_API_PASSWORD");
		}
		bool rootZone = EnvBool("ICINGA2_ROOT_ZONE");
		bool signer = rootZone && IsPrimaryOrdinal();
		String caMode = Env("ICINGA2_CA_MODE", "internal").ToLower();
		if (caMode != "internal" && caMode != "intermediate")
			BOOST_THROW_EXCEPTION(std::invalid_argument(
				"ICINGA2_CA_MODE must be internal or intermediate"));
		bool haEnabled = EnvBool("ICINGA2_HA_ENABLED");
		if (haEnabled)
			ValidateHaTopology(rootZone, host, zone);

		if (signer && caMode == "intermediate")
			ReconcileIntermediateCa();

		String marker = Configuration::DataDir + "/setup.done";
		if (Utility::PathExists(marker)) {
			String identity = ReadFile(marker).Trim();
			String expectedIdentity = host + "\n" + zone;
			if (identity != "complete" && identity != expectedIdentity) {
				BOOST_THROW_EXCEPTION(std::runtime_error(
					"The persistent Icinga data belongs to a different node or zone"));
			}
		} else {
			int rc;
			if (rootZone && signer) {
				rc = SetupMaster(host);
			} else {
				String parentZone;
				std::vector<BootstrapEndpoint> parents;
				if (rootZone) {
					parentZone = zone;
					BootstrapEndpoint parent {
						RequireEnv("ICINGA2_CA_PRIMARY_NAME"),
						RequireEnv("ICINGA2_CA_PRIMARY_ADDRESS"),
						Env("ICINGA2_CA_PRIMARY_PORT", "5665")
					};
					ValidateEndpoint(parent);
					parents.push_back(parent);
				} else {
					parentZone = RequireEnv("ICINGA2_PARENT_ZONE");
					parents = {Parent(0), Parent(1)};
				}
				rc = SetupSatellite(host, zone, listen, parentZone, parents);
			}
			if (rc != 0)
				return false;
			AtomicFile::Write(marker, 0600, host + "\n" + zone + "\n");
		}

		ReconcileRuntimeConfiguration(host, zone, listen);

		if (!Env("ICINGA2_TICKET_SALT").IsEmpty())
			NodeUtility::UpdateConstant("TicketSalt", TicketSalt());

		if (haEnabled)
			WriteHaZones(rootZone, host, zone);
		return true;
	} catch (const std::exception& ex) {
		Log(LogCritical, "EnvironmentBootstrap") << DiagnosticInformation(ex);
		return false;
	}
}
