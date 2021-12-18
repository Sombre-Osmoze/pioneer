//
//  Probe.swift
//  Pioneer
//
//  Created by d-exclaimation on 11:32 PM.
//

import Foundation
import Desolate
import Vapor
import GraphQL
import Graphiti

extension Pioneer {
    /// Actor for handling Websocket distribution and dispatching of client specific actor
    actor Probe: AbstractDesolate, NonStop {
        private let schema: GraphQLSchema
        private let resolver: Resolver
        private let proto: SubProtocol.Type

        init(schema: GraphQLSchema, resolver: Resolver, proto: SubProtocol.Type) {
            self.schema = schema
            self.resolver = resolver
            self.proto = proto
        }
        
        init(schema: Schema<Resolver, Context>, resolver: Resolver, proto: SubProtocol.Type) {
            self.schema = schema.schema
            self.resolver = resolver
            self.proto = proto
        }

        // MARK: - Private mutable states
        private var clients: [UUID: Process] = [:]
        private var drones: [UUID: Desolate<Drone>] = [:]

        func onMessage(msg: Act) async -> Signal {
            switch msg {
            case .connect(process: let process):
                onConnect(with: process)
            case .disconnect(pid: let pid):
                onDisconnect(for: pid)
            case .start(pid: let pid, oid: let oid, gql: let gql):
                onLongRunning(for: pid, with: oid, given: gql)
            case .once(pid: let pid, oid: let oid, gql: let gql):
                onShortLived(for: pid, with: oid, given: gql)
            case .stop(pid: let pid, oid: let oid):
                await onStop(for: pid, with: oid)
            case .outgoing(oid: let oid, process: let process, res: let res):
                onOutgoing(with: oid, to: process, given: res)
            }
            return same
        }
        
        // MARK: - Event callbacks
        
        /// Allocate space and save any verified process
        private func onConnect(with process: Process) {
            clients.update(process.id, with: process)
        }
        
        /// Deallocate the space from a closing process
        private func onDisconnect(for pid: UUID) {
            drones[pid]?.tell(with: .acid)
            clients.delete(pid)
            drones.delete(pid)
        }
        
        /// Long running operation require its own actor, thus initialing one if there were none prior
        private func onLongRunning(for pid: UUID, with oid: String, given gql: GraphQLRequest) {
            guard let process = clients[pid] else { return }
            let drone = drones.getOrElse(pid) {
                spawn(.init(process,
                    schema: schema,
                    resolver: resolver,
                    proto: proto
                ))
            }
            drone.tell(with: .start(oid: oid, gql: gql))
            drones.update(pid, with: drone)
        }
        
        /// Short lived operation is processed immediately and pipe back later
        private func onShortLived(for pid: UUID, with oid: String, given gql: GraphQLRequest) {
            guard let process = clients[pid] else { return }

            let future = execute(gql, ctx: process.ctx, req: process.req)

            pipeToSelf(future: future) { res in
                switch res {
                case .success(let result):
                    return .outgoing(oid: oid, process: process,
                        res: .from(type: self.proto.next, id: oid, result)
                    )
                case .failure(let error):
                    let result: GraphQLResult = .init(data: nil, errors: [.init(message: error.localizedDescription)])
                    return .outgoing(oid: oid, process: process,
                        res: .from(type: self.proto.next, id: oid, result)
                    )
                }
            }
        }

        /// Stopping any operation to client specific actor
        private func onStop(for pid: UUID, with oid: String) async {
            await drones[pid]?.task(with: .stop(oid: oid))
        }
        
        /// Message for pipe to self result after processing short lived operation
        private func onOutgoing(with oid: String, to process: Process, given msg: GraphQLMessage) {
            process.send(msg.jsonString)
            process.send(GraphQLMessage(id: oid, type: proto.complete).jsonString)
        }
        
        // MARK: - Utility methods
        
        /// Execute short-lived GraphQL Operation
        private func execute(_ gql: GraphQLRequest, ctx: Context, req: Request) -> Future<GraphQLResult> {
            do {
                return try graphql(
                    schema: schema,
                    request: gql.query,
                    rootValue: resolver,
                    context: ctx,
                    eventLoopGroup: req.eventLoop,
                    variableValues: gql.variables ?? [:],
                    operationName: gql.operationName
                )
            } catch {
                return req.eventLoop.next().makeFailedFuture(error)
            }
        }

        enum Act {
            case connect(process: Process)
            case disconnect(pid: UUID)
            case start(pid: UUID, oid: String, gql: GraphQLRequest)
            case once(pid: UUID, oid: String, gql: GraphQLRequest)
            case stop(pid: UUID, oid: String)
            case outgoing(oid: String, process: Process, res: GraphQLMessage)
        }
    }
}
